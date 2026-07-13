import AppKit

extension LockController {
    // MARK: - In-lock snapshot button (paired with LockOverlayDebug)

    /// Geometry of the snapshot button rendered by LockOverlayDebug at
    /// the top-right of the main screen. Kept in one place so the
    /// event-tap region check and the SwiftUI button position can't
    /// drift apart.
    static let inlineSnapshotButtonWidth:  CGFloat = 140
    static let inlineSnapshotButtonHeight: CGFloat = 28
    static let inlineSnapshotButtonMargin: CGFloat = 12

    /// `point` is in CGEvent global coordinates (top-left origin of the
    /// PRIMARY display = `NSScreen.screens.first`, with Y growing down).
    /// Returns true when the user clicked inside an on-screen snapshot
    /// button — only when the overlay is on, otherwise the button isn't
    /// drawn and we don't want to silently swallow clicks at the
    /// top-right corner of any display.
    ///
    /// `LockOverlayDebug` paints a snapshot button at the top-right of
    /// EVERY lock window — one per display. The user can click any of
    /// them. We translate each screen's top-right rectangle from
    /// NSScreen arrangement coords (Y up, anchored at the screen
    /// arrangement origin) into CGEvent coords (Y down, anchored at
    /// the primary display's top-left) and accept the click if it
    /// lands in any of those rectangles. Single-display setups fall
    /// out trivially because the loop has just one iteration with
    /// primary == main.
    func isInsideInlineSnapshotRegion(_ point: CGPoint) -> Bool {
        guard AppSettings.shared.lockOverlayDebugLevel != .off else { return false }
        guard let primary = NSScreen.screens.first else { return false }
        let w = Self.inlineSnapshotButtonWidth
        let h = Self.inlineSnapshotButtonHeight
        let m = Self.inlineSnapshotButtonMargin
        // primary.frame.minX is 0 by Apple's convention (NSScreen.screens.first
        // is anchored at the global origin), but keep the subtraction explicit
        // so the math survives any future change in that contract.
        for screen in NSScreen.screens {
            let region = CGRect(
                x: screen.frame.maxX - m - w - primary.frame.minX,
                y: primary.frame.maxY - screen.frame.maxY + m,
                width: w,
                height: h
            )
            if region.contains(point) { return true }
        }
        return false
    }

    /// Write a full DebugLog snapshot to disk and bump snapshotPulse so
    /// the overlay can flash a "SAVED" toast. PerfMetrics records this
    /// as an event so the timestamp lands in the snapshot's own Recent
    /// Events section — handy for cross-correlating "I clicked here"
    /// against the latency curve.
    func triggerInlineSnapshot() {
        let snap = DebugLog.snapshot()
        DebugLog.writeForced(snap)
        snapshotPulse &+= 1
        DebugLog.log("inline snapshot pulse=\(snapshotPulse)")
        PerfMetrics.shared.recordEvent("snapshot")
    }

    /// Unified cursor-jump detector. Called from every event path that
    /// carries a meaningful `event.location` (mouseMoved, keyDown, …),
    /// so a jump that lands BETWEEN keystrokes without an intervening
    /// mouseMoved (the live symptom we're chasing) is still caught.
    /// Auto-snapshots the surrounding event ring on detection, throttled
    /// to at most one per 0.5 s so a settled-in jump can't fire dozens of
    /// redundant ones.
    ///
    /// Threshold: 500 px. The earlier 300 px tripped on legitimate user
    /// motion now that mouseMoved is passed through — bursts of motion
    /// arriving in the same callback tick can accumulate a 400+ px delta
    /// even at normal hand-speeds. 500 px is still well below any
    /// plausible OS-driven cursor warp (e.g. multi-monitor jump) but
    /// outside the envelope of single-frame mouseMoved batching.
    /// Auto-snapshot is gated on verbosePerfEnabled at the call site, so
    /// no overhead in normal use.
    func checkAnyEventCursorJump(_ loc: CGPoint, eventLabel: String) {
        let now = Date().timeIntervalSinceReferenceDate
        defer {
            lastAnyEventCursor = loc
            lastAnyEventAt = now
        }
        guard lastAnyEventAt > 0 else { return }
        // Synthetic key vs synthetic mouseMoved events have unrelated
        // event.location values (each picks its own default), so the
        // perf-test harness produces 500+ px deltas every few events
        // even though no real cursor warp happened. Auto-snapshots
        // inside that test would inject ~100 ms of disk I/O per fire
        // and break the latency measurement we're trying to take.
        #if DEBUG
        if PerfTestRunner.isRunning { return }
        #endif
        let dx = loc.x - lastAnyEventCursor.x
        let dy = loc.y - lastAnyEventCursor.y
        let dist = (dx * dx + dy * dy).squareRoot()
        guard dist > 500 else { return }
        guard now - lastAutoSnapshotAt > 0.5 else { return }
        let dt = now - lastAnyEventAt
        let fromX = Int(lastAnyEventCursor.x)
        let fromY = Int(lastAnyEventCursor.y)
        let toX = Int(loc.x)
        let toY = Int(loc.y)
        PerfMetrics.shared.recordEvent(
            "*** CURSOR JUMP via=\(eventLabel) from=(\(fromX),\(fromY)) to=(\(toX),\(toY)) Δ=\(Int(dist))px in \(Int(dt*1000))ms"
        )
        DebugLog.log("cursor jump: via \(eventLabel) from=(\(fromX),\(fromY)) to=(\(toX),\(toY)) Δ=\(Int(dist))px in \(Int(dt*1000))ms — auto snapshot")
        triggerInlineSnapshot()
        lastAutoSnapshotAt = now
    }
}

#if DEBUG
extension LockController {
    /// Direct-injection test path used by PerfTestHarness mode A. Calls
    /// handleEvent on the same MainActor a real tap callback would, so
    /// the result is identical apart from skipping the OS tap roundtrip.
    @MainActor
    func _testInjectEvent(_ event: CGEvent, type: CGEventType) {
        let t0 = PerfMetrics.now()
        _ = handleEvent(type: type, event: event)
        PerfMetrics.shared.recordCallback(machTicks: PerfMetrics.now() &- t0, type: type)
    }
}
#endif
