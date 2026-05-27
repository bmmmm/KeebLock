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
    /// Cells-wiped threshold (0…1) at which `advanceStage` fires. 1.0
    /// requires the entire grid before a fresh stage starts; lower
    /// values let perpetually-unreachable cells (system-bound F-keys
    /// in positional mode) not block progress forever. Captured at
    /// init — live setting changes apply on the next lock session.
    private let stageThreshold: Double

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
          cellsPerAxis: Int,
          stageThreshold: Double) {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let queue = dev.makeCommandQueue() else { return nil }
        device = dev
        commandQueue = queue
        screenFrame = screen.frame
        self.fixedBg = fixedBg
        self.fixedPixel = fixedPixel
        self.stageThreshold = max(0.50, min(1.0, stageThreshold))

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
        let advanceTarget = max(1, Int((Double(total) * stageThreshold).rounded()))
        let advance = wipedCellCount >= advanceTarget
        stateLock.unlock()

        PerfMetrics.shared.recordMainHop()
        DispatchQueue.main.async { self.wipedFraction = min(1.0, frac) }
        if advance { advanceStage() }
    }

    /// Clears up to `count` cells inside the key's bounding rectangle
    /// `bounds` (normalised to [0,1] × [0,1] on the keyboard). Cells
    /// outside the rectangle are NEVER wiped by this call — once
    /// every cell inside is gone, repeating the same key has no
    /// further effect. That's the whole point: hammering the spacebar
    /// no longer slowly clears the entire screen, the wipe stays
    /// confined to where the key physically sits.
    ///
    /// Inside the rectangle, intact cells are picked at random
    /// (shuffled) so the visible reveal looks organic across many
    /// presses rather than always wiping the same cells in the same
    /// order.
    func wipeAtNormalizedPosition(_ pos: CGPoint,
                                  count requestedCount: Int,
                                  bounds: CGRect) {
        let count = max(1, requestedCount)
        stateLock.lock()
        let w = maskDims.w
        let h = maskDims.h

        let xMinCell = max(0, Int((bounds.minX * Double(w)).rounded(.down)))
        let xMaxCell = min(w - 1, Int((bounds.maxX * Double(w)).rounded(.down)))
        let yMinCell = max(0, Int((bounds.minY * Double(h)).rounded(.down)))
        let yMaxCell = min(h - 1, Int((bounds.maxY * Double(h)).rounded(.down)))

        guard xMinCell <= xMaxCell, yMinCell <= yMaxCell else {
            stateLock.unlock()
            return
        }

        var intactCells: [Int] = []
        intactCells.reserveCapacity((xMaxCell - xMinCell + 1) * (yMaxCell - yMinCell + 1))
        for ny in yMinCell...yMaxCell {
            for nx in xMinCell...xMaxCell {
                let idx = ny * w + nx
                if maskBytes[idx] != 0 {
                    intactCells.append(idx)
                }
            }
        }
        intactCells.shuffle()

        let toWipe = min(count, intactCells.count)
        for i in 0..<toWipe {
            let idx = intactCells[i]
            maskBytes[idx] = 0
            if let removeAt = remainingIndices.firstIndex(of: idx) {
                remainingIndices.remove(at: removeAt)
            }
            wipedCellCount += 1
        }

        let madeProgress = toWipe > 0
        if madeProgress { maskDirty = true }
        let total = maskBytes.count
        let frac = Double(wipedCellCount) / Double(total)
        let advanceTarget = max(1, Int((Double(total) * stageThreshold).rounded()))
        let advance = wipedCellCount >= advanceTarget
        stateLock.unlock()

        if madeProgress {
            PerfMetrics.shared.recordMainHop()
            DispatchQueue.main.async { self.wipedFraction = min(1.0, frac) }
        }
        if advance { advanceStage() }
    }

    /// Read-only snapshot of mask state for the diagnostic log.
    /// Callable from any thread — locks the same mutex the wipe paths
    /// use so reads are coherent with concurrent writes.
    struct State {
        let frame: CGRect
        let stage: Int
        let cellsW: Int
        let cellsH: Int
        let wipedCells: Int
        let totalCells: Int

        var intactCells: Int { totalCells - wipedCells }
    }

    func snapshotState() -> State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return State(
            frame: screenFrame,
            stage: stage,
            cellsW: maskDims.w,
            cellsH: maskDims.h,
            wipedCells: wipedCellCount,
            totalCells: maskDims.w * maskDims.h
        )
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
        PerfMetrics.shared.recordMainHop()
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
