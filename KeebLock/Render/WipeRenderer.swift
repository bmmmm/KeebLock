import AppKit
import Combine
import Metal
import MetalKit
import SwiftUI

// One WipeRenderer per screen. MTKView runs at 60fps; draw(in:) may be called from a
// private Metal thread. All shared mutable state is protected by `stateLock`.
// @Published updates always hop to MainActor.
//
// Each keystroke clears exactly one random mask cell. Mask resolution is fixed
// independent of physical screen pixels so the "pixel" feel stays minimal.
final class WipeRenderer: NSObject, ObservableObject, MTKViewDelegate {

    let metalView: MTKView

    @Published private(set) var stage: Int = 1
    @Published private(set) var wipedFraction: Double = 0

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var renderPipeline: MTLRenderPipelineState?

    private let fixedColor: SIMD4<Float>?

    // Shared mutable state
    private let stateLock = NSLock()
    private var maskTexture: MTLTexture?
    private var maskBytes: [UInt8] = []
    private var maskDirty = false
    private var remainingIndices: [Int] = []
    private var wipedCellCount = 0
    private var currentBgColor: SIMD4<Float> = .one

    private let maskDims: (w: Int, h: Int)

    let screenFrame: CGRect

    // Mask cells along the X axis. Y derived from screen aspect.
    // Driven by AppSettings.pixelFineness (slider 1-10 → cells 8..44).
    init?(screen: NSScreen, fixedColor: SIMD4<Float>? = nil, cellsPerAxis: Int) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else { return nil }
        device = dev
        commandQueue = queue
        screenFrame = screen.frame
        self.fixedColor = fixedColor

        let aspect = screen.frame.height / max(1, screen.frame.width)
        let cellsX = max(2, cellsPerAxis)
        let cellsY = max(1, Int((Double(cellsX) * Double(aspect)).rounded()))
        maskDims = (cellsX, cellsY)

        let total = cellsX * cellsY
        maskBytes = [UInt8](repeating: 255, count: total)
        remainingIndices = (0..<total).shuffled()
        currentBgColor = fixedColor ?? Self.randomColor()

        let view = MTKView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            device: dev
        )
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        metalView = view

        super.init()
        setupPipeline()
        rebuildMaskTexture()
        view.delegate = self
    }

    // MARK: - Public API (main thread)

    /// Clears one random unwiped cell. Call once per keystroke.
    func wipeRandomCell() {
        stateLock.lock()
        guard let idx = remainingIndices.popLast() else {
            stateLock.unlock()
            return
        }
        maskBytes[idx] = 0
        maskDirty = true
        wipedCellCount += 1
        let total = maskBytes.count
        let frac = Double(wipedCellCount) / Double(total)
        let advance = wipedCellCount >= total
        stateLock.unlock()

        DispatchQueue.main.async { self.wipedFraction = min(1.0, frac) }
        if advance { advanceStage() }
    }

    /// Stops the display link before window teardown.
    func stop() {
        metalView.delegate = nil
        metalView.isPaused = true
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Mask resolution is fixed; nothing to do here.
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // Snapshot state
        stateLock.lock()
        let color = currentBgColor
        let dirty = maskDirty
        let snapshot = dirty ? maskBytes : []
        if dirty { maskDirty = false }
        stateLock.unlock()

        // Push mask updates to GPU
        if dirty, let mask = maskTexture {
            mask.replace(
                region: MTLRegionMake2D(0, 0, maskDims.w, maskDims.h),
                mipmapLevel: 0,
                withBytes: snapshot,
                bytesPerRow: maskDims.w
            )
        }

        guard let mask = maskTexture else { return }

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

    // MARK: - Private

    private func advanceStage() {
        stateLock.lock()
        currentBgColor = fixedColor ?? Self.randomColor()
        let total = maskDims.w * maskDims.h
        maskBytes = [UInt8](repeating: 255, count: total)
        remainingIndices = (0..<total).shuffled()
        wipedCellCount = 0
        maskDirty = true
        stateLock.unlock()
        DispatchQueue.main.async {
            self.stage += 1
            self.wipedFraction = 0
        }
    }

    private func setupPipeline() {
        guard let lib = device.makeDefaultLibrary() else {
            NSLog("[KeebLock] Metal: no default shader library")
            return
        }
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
        if renderPipeline == nil {
            NSLog("[KeebLock] Metal: render pipeline creation failed")
        }
    }

    private func rebuildMaskTexture() {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width:  maskDims.w,
            height: maskDims.h,
            mipmapped: false
        )
        desc.usage       = [.shaderRead]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        tex.replace(
            region: MTLRegionMake2D(0, 0, maskDims.w, maskDims.h),
            mipmapLevel: 0,
            withBytes: maskBytes,
            bytesPerRow: maskDims.w
        )
        maskTexture = tex
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
    