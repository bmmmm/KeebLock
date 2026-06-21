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

    /// Last integer percent already pushed to `wipedFraction`. The HUD only
    /// renders `Int(wipedFraction * 100)`, so publishing every sub-percent
    /// cell wipe would churn the @Published binding (and re-render the HUD
    /// stats row) up to ~100×/s during fast typing for no visible change.
    /// Touched only on the main thread, inside the wipe publish hops.
    private var lastPublishedPercent: Int = -1

    /// True for the no-Metal fallback. The instance is fully constructed
    /// (so LockView can hold a non-optional reference and HUDView can
    /// observe stage/wipedFraction) but skips pipeline setup; draw(),
    /// wipe*, and stop() short-circuit. The lock window falls back to a
    /// SwiftUI Color so the user still sees an opaque cover.
    let isPlaceholder: Bool

    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
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

    init(screen: NSScreen,
         fixedBg: SIMD4<Float>?,
         fixedPixel: SIMD4<Float>?,
         cellsPerAxis: Int,
         stageThreshold: Double) {
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

        let dev = MTLCreateSystemDefaultDevice()
        let queue = dev?.makeCommandQueue()
        device = dev
        commandQueue = queue
        isPlaceholder = (dev == nil || queue == nil)

        let view = MTKView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            device: dev
        )
        // On-demand rendering. The fragmentWipe shader is static between
        // wipes (no time uniform — see Shaders.metal), so continuous
        // rendering at the display refresh rate would redraw bit-identical
        // frames the entire time the lock sits idle. isPaused stops the
        // internal timer; draw() now fires only when a wipe/advanceStage
        // marks the view needsDisplay. Saves the idle GPU spin per screen.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
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
        if !isPlaceholder {
            setupPipeline()
            rebuildMaskTexture()
            view.delegate = self
        }
    }

    // MARK: - Public API

    func wipeRandomCell() {
        // Wipe entry points run on the main-serialized keystroke hot path;
        // `recordMainHop()` and the @Published mutations below assume it.
        // This class is `nonisolated`, so the invariant rests on call-site
        // discipline — assert it (debug-only, stripped in release) so an
        // accidental off-main caller is caught instead of racing silently.
        dispatchPrecondition(condition: .onQueue(.main))
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
        let clampedFrac = min(1.0, frac)
        DispatchQueue.main.async { [weak self] in self?.publishWipe(fraction: clampedFrac) }
        if advance { advanceStage() }
    }

    /// Main-thread publish hop shared by both wipe paths: requests the
    /// on-demand redraw (the mask just changed) and pushes `wipedFraction`
    /// only when the integer percent actually moved.
    private func publishWipe(fraction: Double) {
        metalView.needsDisplay = true
        let pct = Int(fraction * 100)
        if pct != lastPublishedPercent {
            lastPublishedPercent = pct
            wipedFraction = fraction
        }
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
        // Same main-thread invariant as wipeRandomCell() — see there.
        dispatchPrecondition(condition: .onQueue(.main))
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
            let clampedFrac = min(1.0, frac)
            DispatchQueue.main.async { [weak self] in self?.publishWipe(fraction: clampedFrac) }
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
        guard !isPlaceholder, let commandQueue else { return }
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
        // Mask resolution is fixed, but under on-demand rendering the very
        // first frame (and any later resize) must be requested explicitly —
        // otherwise the lock window would come up un-drawn / black.
        view.needsDisplay = true
    }

    func draw(in view: MTKView) {
        guard let commandQueue,
              let drawable = view.currentDrawable,
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.metalView.needsDisplay = true
            self.stage += 1
            self.wipedFraction = 0
            self.lastPublishedPercent = 0
        }
    }

    private func setupPipeline() {
        guard let device, let lib = device.makeDefaultLibrary() else {
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
        guard let device, let tex = device.makeTexture(descriptor: desc) else { return }
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
