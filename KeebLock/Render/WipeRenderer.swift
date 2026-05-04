import AppKit
import Combine
import Metal
import MetalKit
import SwiftUI

// One WipeRenderer per screen. MTKView is driven at 60 fps (isPaused = false),
// so draw(in:) may be called from a private Metal thread. All shared mutable
// state is protected by `stateLock`. @Published updates always hop to MainActor.
final class WipeRenderer: NSObject, ObservableObject, MTKViewDelegate {

    let metalView: MTKView

    @Published private(set) var stage: Int = 1
    @Published private(set) var wipedFraction: Double = 0

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var renderPipeline: MTLRenderPipelineState?
    private var computePipeline: MTLComputePipelineState?

    // Optional fixed color; nil = random per stage
    private let fixedColor: SIMD4<Float>?

    // Locked state — accessed from main thread and Metal thread
    private let stateLock = NSLock()
    private var maskTexture: MTLTexture?
    private var pendingWipes: [(center: SIMD2<Float>, radius: Float)] = []
    private var needsRebuild = false
    private var currentBgColor: SIMD4<Float> = .one

    // Main-thread-only tracking (wipe(at:) is always called on main thread)
    private var wipedAreaEstimate: Double = 0
    private var totalMaskPixels: Double = 1

    // Snapshot used by main thread for coordinate conversion; updated after rebuild
    private var maskDims: (w: Int, h: Int) = (1, 1)

    let screenFrame: CGRect

    init?(screen: NSScreen, fixedColor: SIMD4<Float>? = nil) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else { return nil }
        device = dev
        commandQueue = queue
        screenFrame = screen.frame
        self.fixedColor = fixedColor

        // Pre-compute expected mask size from physical resolution
        let scale = screen.backingScaleFactor
        let pw = max(1, Int(screen.frame.width  * scale) / 4)
        let ph = max(1, Int(screen.frame.height * scale) / 4)
        maskDims = (pw, ph)
        totalMaskPixels = Double(pw) * Double(ph)
        currentBgColor = fixedColor ?? Self.randomColor()

        let view = MTKView(frame: screen.frame, device: dev)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        metalView = view

        super.init()
        setupPipelines()
        view.delegate = self
    }

    // MARK: - Public API (called from main thread)

    // Wipe a disc at `screenLocalPoint` (AppKit coords: origin = bottom-left of screen).
    // `radius` is in points.
    func wipe(at screenLocalPoint: CGPoint, radius: CGFloat) {
        let sw = Double(screenFrame.width)
        let sh = Double(screenFrame.height)
        let mw = Double(maskDims.w)
        let mh = Double(maskDims.h)

        // Screen-local → mask texture (top-left origin, downscaled)
        let mx = Float(screenLocalPoint.x / sw * mw)
        let my = Float((sh - Double(screenLocalPoint.y)) / sh * mh)
        let mr = Float(radius / sw * mw)

        wipedAreaEstimate += .pi * Double(mr) * Double(mr)
        let fraction = min(1.0, wipedAreaEstimate / totalMaskPixels)

        stateLock.lock()
        pendingWipes.append((center: SIMD2(mx, my), radius: mr))
        stateLock.unlock()

        DispatchQueue.main.async { self.wipedFraction = fraction }

        if fraction >= 0.99 { advanceStage() }
    }

    // Must be called on the main thread before releasing the renderer.
    // Stops the CVDisplayLink so no draw(in:) calls fire after teardown.
    func stop() {
        metalView.delegate = nil
        metalView.isPaused = true
    }

    func resetState() {
        wipedAreaEstimate = 0
        stateLock.lock()
        currentBgColor = fixedColor ?? Self.randomColor()
        needsRebuild = true
        pendingWipes.removeAll()
        stateLock.unlock()
        DispatchQueue.main.async {
            self.stage = 1
            self.wipedFraction = 0
        }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let w = max(1, Int(size.width) / 4)
        let h = max(1, Int(size.height) / 4)
        guard let tex = buildMask(width: w, height: h) else { return }
        stateLock.lock()
        maskTexture = tex
        needsRebuild = false
        stateLock.unlock()
        DispatchQueue.main.async {
            self.maskDims = (w, h)
            self.totalMaskPixels = Double(w) * Double(h)
        }
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // --- Resolve pending state under lock ---
        stateLock.lock()
        let rebuildNeeded = needsRebuild || maskTexture == nil
        if rebuildNeeded { needsRebuild = false }
        let color = currentBgColor
        let wipes = pendingWipes
        pendingWipes.removeAll(keepingCapacity: true)
        stateLock.unlock()

        if rebuildNeeded {
            let w = max(1, Int(view.drawableSize.width)  / 4)
            let h = max(1, Int(view.drawableSize.height) / 4)
            if let tex = buildMask(width: w, height: h) {
                stateLock.lock()
                maskTexture = tex
                stateLock.unlock()
                DispatchQueue.main.async {
                    self.maskDims = (w, h)
                    self.totalMaskPixels = Double(w) * Double(h)
                }
            }
        }

        stateLock.lock()
        let mask = maskTexture
        stateLock.unlock()
        guard let mask else { return }

        // --- Compute: clear wipe discs ---
        if !wipes.isEmpty, let cPipeline = computePipeline,
           let enc = cmdBuf.makeComputeCommandEncoder() {
            enc.setComputePipelineState(cPipeline)
            enc.setTexture(mask, index: 0)
            let tw = cPipeline.threadExecutionWidth
            let th = max(1, cPipeline.maxTotalThreadsPerThreadgroup / tw)
            let tgSize = MTLSize(width: tw, height: th, depth: 1)
            let grid   = MTLSize(width: mask.width, height: mask.height, depth: 1)
            for wipe in wipes {
                var c = wipe.center; var r = wipe.radius
                enc.setBytes(&c, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                enc.setBytes(&r, length: MemoryLayout<Float>.size,        index: 1)
                enc.dispatchThreads(grid, threadsPerThreadgroup: tgSize)
            }
            enc.endEncoding()
        }

        // --- Render: composite mask × bgColor ---
        passDesc.colorAttachments[0].loadAction  = .clear
        passDesc.colorAttachments[0].clearColor  = MTLClearColorMake(0, 0, 0, 0)
        passDesc.colorAttachments[0].storeAction = .store

        if let rPipeline = renderPipeline,
           let enc = cmdBuf.makeRenderCommandEncoder(descriptor: passDesc) {
            enc.setRenderPipelineState(rPipeline)
            enc.setFragmentTexture(mask, index: 0)
            var col = color
            enc.setFragmentBytes(&col, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    // MARK: - Private helpers

    private func advanceStage() {
        wipedAreaEstimate = 0
        stateLock.lock()
        currentBgColor = fixedColor ?? Self.randomColor()
        needsRebuild = true
        pendingWipes.removeAll()
        stateLock.unlock()
        DispatchQueue.main.async {
            self.stage += 1
            self.wipedFraction = 0
        }
    }

    private func setupPipelines() {
        guard let lib = device.makeDefaultLibrary() else {
            NSLog("[KeebLock] Metal: no default shader library")
            return
        }
        // Render pipeline
        let rd = MTLRenderPipelineDescriptor()
        rd.vertexFunction   = lib.makeFunction(name: "vertexPassthrough")
        rd.fragmentFunction = lib.makeFunction(name: "fragmentWipe")
        rd.colorAttachments[0].pixelFormat = .bgra8Unorm
        let att = rd.colorAttachments[0]!
        att.isBlendingEnabled             = true
        att.sourceRGBBlendFactor          = .sourceAlpha
        att.destinationRGBBlendFactor     = .oneMinusSourceAlpha
        att.sourceAlphaBlendFactor        = .one
        att.destinationAlphaBlendFactor   = .oneMinusSourceAlpha
        renderPipeline = try? device.makeRenderPipelineState(descriptor: rd)

        // Compute pipeline
        if let fn = lib.makeFunction(name: "clearDisc") {
            computePipeline = try? device.makeComputePipelineState(function: fn)
        }

        if renderPipeline  == nil { NSLog("[KeebLock] Metal: render pipeline creation failed") }
        if computePipeline == nil { NSLog("[KeebLock] Metal: compute pipeline creation failed") }
    }

    // Builds a new all-ones (fully-opaque) r8 mask texture.
    // Called from both main thread and Metal thread — only uses device (thread-safe).
    private func buildMask(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width:  width,
            height: height,
            mipmapped: false
        )
        desc.usage       = [.shaderRead, .shaderWrite]
        desc.storageMode = .shared  // CPU-writable for initial fill; fine on Apple Silicon
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        let bytes = [UInt8](repeating: 255, count: width * height)
        tex.replace(
            region:       MTLRegionMake2D(0, 0, width, height),
            mipmapLevel:  0,
            withBytes:    bytes,
            bytesPerRow:  width
        )
        return tex
    }

    private static func randomColor() -> SIMD4<Float> {
        let h = CGFloat.random(in: 0..<1)
        let s = CGFloat.random(in: 0.55...0.75)
        let b = CGFloat.random(in: 0.45...0.6)
        let c = NSColor(hue: h, saturation: s, brightness: b, alpha: 1)
                    .usingColorSpace(.sRGB) ?? .red
        return SIMD4<Float>(Float(c.redComponent), Float(c.greenComponent),
                            Float(c.blueComponent), 1.0)
    }
}

// MARK: - SwiftUI bridge

struct WipeView: NSViewRepresentable {
    let renderer: WipeRenderer
    func makeNSView(context: Context)                        -> MTKView { renderer.metalView }
    func updateNSView(_ nsView: MTKView, context: Context)   {}
}
