import AppKit
import Combine
import Metal
import MetalKit
import SwiftUI

// One WipeRenderer per screen. Renders a fullscreen quad whose colour is a lerp
// between two SIMD4 colours (bg, pixel) driven by an r8 mask texture. Each
// keystroke clears one random mask cell.
final class WipeRenderer: NSObject, ObservableObject, MTKViewDelegate {

    let metalView: MTKView

    @Published private(set) var stage: Int = 1
    @Published private(set) var wipedFraction: Double = 0

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var renderPipeline: MTLRenderPipelineState?

    private let fixedBg: SIMD4<Float>?
    private let fixedPixel: SIMD4<Float>?

    private let stateLock = NSLock()
    private var maskTexture: MTLTexture?
    private var maskBytes: [UInt8] = []
    private var maskDirty = false
    private var remainingIndices: [Int] = []
    private var wipedCellCount = 0
    private var currentBg: SIMD4<Float>
    private var currentPixel: SIMD4<Float>

    private let maskDims: (w: Int, h: Int)

    let screenFrame: CGRect

    init?(screen: NSScreen,
          fixedBg: SIMD4<Float>?,
          fixedPixel: SIMD4<Float>?,
          cellsPerAxis: Int) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else { return nil }
        device = dev
        commandQueue = queue
        screenFrame = screen.frame
        self.fixedBg = fixedBg
        self.fixedPixel = fixedPixel

        let aspect = screen.frame.height / max(1, screen.frame.width)
        let cellsX = max(2, cellsPerAxis)
        let cellsY = max(1, Int((Double(cellsX) * Double(aspect)).rounded()))
        maskDims = (cellsX, cellsY)

        let total = cellsX * cellsY
        maskBytes = [UInt8](repeating: 255, count: total)
        remainingIndices = (0..<total).shuffled()
        currentBg = fixedBg ?? Self.randomColor()
        currentPixel = fixedPixel ?? Self.randomColor()

        let view = MTKView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            device: dev
        )
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = false
        // Must be false so transparent (alpha=0) fragments show the desktop through the window.
        view.layer?.isOpaque = false
        if let metalLayer = view.layer as? CAMetalLayer {
            metalLayer.isOpaque = false
            metalLayer.backgroundColor = CGColor(gray: 0, alpha: 0)
        }
        metalView = view

        super.init()
        setupPipeline()
        rebuildMaskTexture()
        view.delegate = self
    }

    // MARK: - Public API

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

    /// Clears one or more cells centred on the normalised position
    /// `(x, y) ∈ [0,1] × [0,1]`, with x left→right and y top→bottom —
    /// matching the keyboard-to-screen mapping in `KeyboardPositionMap`.
    ///
    /// `count` is how many cells the keystroke should clear; the
    /// caller derives it from cells-per-axis so the visual wipe per
    /// key stays roughly consistent across pixel-fineness settings
    /// (more cells per stroke when the grid is finer).
    ///
    /// If the centre cell is already wiped, expansion proceeds in
    /// Chebyshev rings (max(|dx|,|dy|) = r) until enough intact cells
    /// are found or the grid is exhausted. Each ring is shuffled so
    /// repeated presses on the same key don't always pick the same
    /// neighbour, keeping the visual reveal organic.
    func wipeAtNormalizedPosition(_ pos: CGPoint, count requestedCount: Int) {
        let count = max(1, requestedCount)
        stateLock.lock()
        let w = maskDims.w
        let h = maskDims.h
        let cx = max(0, min(w - 1, Int(pos.x * Double(w))))
        let cy = max(0, min(h - 1, Int(pos.y * Double(h))))

        var wipedThisCall = 0
        var radius = 0
        let maxRadius = max(w, h)
        while wipedThisCall < count, radius <= maxRadius {
            let candidates = chebyshevRing(cx: cx, cy: cy, radius: radius).shuffled()
            for (nx, ny) in candidates {
                guard nx >= 0, nx < w, ny >= 0, ny < h else { continue }
                let idx = ny * w + nx
                if maskBytes[idx] == 0 { continue }
                maskBytes[idx] = 0
                if let removeAt = remainingIndices.firstIndex(of: idx) {
                    remainingIndices.remove(at: removeAt)
                }
                wipedCellCount += 1
                wipedThisCall += 1
                if wipedThisCall >= count { break }
            }
            radius += 1
        }

        let madeProgress = wipedThisCall > 0
        if madeProgress { maskDirty = true }
        let total = maskBytes.count
        let frac = Double(wipedCellCount) / Double(total)
        let advance = wipedCellCount >= total
        stateLock.unlock()

        if madeProgress {
            DispatchQueue.main.async { self.wipedFraction = min(1.0, frac) }
        }
        if advance { advanceStage() }
    }

    private func chebyshevRing(cx: Int, cy: Int, radius: Int) -> [(Int, Int)] {
        if radius == 0 { return [(cx, cy)] }
        var cells: [(Int, Int)] = []
        cells.reserveCapacity(8 * radius)
        let r = radius
        for dx in -r...r {
            cells.append((cx + dx, cy - r))
            cells.append((cx + dx, cy + r))
        }
        if r >= 2 {
            for dy in (-r + 1)...(r - 1) {
                cells.append((cx - r, cy + dy))
                cells.append((cx + r, cy + dy))
            }
        }
        return cells
    }

    func stop() {
        metalView.delegate = nil
        metalView.isPaused = true
        // Drain any in-flight command buffer so the GPU isn't still
        // pointing at our textures / drawables when LockWindowManager.hide()
        // nils contentView and drops the renderer in the same runloop tick.
        // Without this drain the previous frame's `presentDrawable` callback
        // can fire against a torn-down layer chain on slow GPU schedules.
        let drain = commandQueue.makeCommandBuffer()
        drain?.commit()
        drain?.waitUntilCompleted()
        metalView.releaseDrawables()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Mask resolution is fixed; nothing to do here.
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let passDesc = view.currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        stateLock.lock()
        let bg = currentBg
        let px = currentPixel
        let dirty = maskDirty
        let snapshot = dirty ? maskBytes : []
        if dirty { maskDirty = false }
        stateLock.unlock()

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
            var bgC = bg
            var pxC = px
            enc.setFragmentBytes(&bgC, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            enc.setFragmentBytes(&pxC, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    // MARK: - Private

    private func advanceStage() {
        stateLock.lock()
        currentBg = fixedBg ?? Self.randomColor()
        currentPixel = fixedPixel ?? Self.randomColor()
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
            DebugLog.log("Metal: no default shader library")
            return
        }
        let rd = MTLRenderPipelineDescriptor()
        rd.vertexFunction   = lib.makeFunction(name: "vertexPassthrough")
        rd.fragmentFunction = lib.makeFunction(name: "fragmentWipe")
        rd.colorAttachments[0].pixelFormat = .bgra8Unorm
        // colorAttachments[0] is guaranteed to exist after the pixelFormat
        // assignment above — Metal's descriptor doesn't return nil for an
        // index it just accepted a write at.
        let att = rd.colorAttachments[0]!
        att.isBlendingEnabled             = true
        att.sourceRGBBlendFactor          = .sourceAlpha
        att.destinationRGBBlendFactor     = .oneMinusSourceAlpha
        att.sourceAlphaBlendFactor        = .one
        att.destinationAlphaBlendFactor   = .oneMinusSourceAlpha
        renderPipeline = try? device.makeRenderPipelineState(descriptor: rd)
        if renderPipeline == nil {
            DebugLog.log("Metal: render pipeline creation failed")
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
