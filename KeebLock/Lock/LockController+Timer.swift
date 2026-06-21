import AppKit

/// NSObject adapter so `CADisplayLink`'s target/@objc selector contract
/// can call into a Swift closure that lives on LockController. The
/// closure runs on the main thread (CADisplayLink delivers on whatever
/// runloop it was added to — we use `.main`), which matches the
/// LockController's MainActor isolation by location.
@MainActor
final class DisplayLinkBridge: NSObject {
    let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
    @objc func fire() { callback() }
}

extension LockController {
    // MARK: - Timer (pause-aware)

    func startTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        unlockTimer = timer
        startDisplayLink()
    }

    func stopTimer() {
        unlockTimer?.invalidate()
        unlockTimer = nil
        stopDisplayLink()
    }

    /// Native-refresh-rate driver for the @Observable `displayTick`. Each
    /// fire bumps the tick, which propagates to subscribed views as a
    /// transaction for the same frame the system was already going to
    /// render — view body re-evals fit inside the rendering window
    /// instead of carving a separate MainActor preemption out of the
    /// next event-tap callback (which is what a 1 Hz `Timer.tick()`
    /// version did, surfacing as 5 ms key-callback p99 outliers).
    func startDisplayLink() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            DebugLog.log("startDisplayLink: NSScreen.main nil and no screens — HUD tick disabled")
            return
        }
        let bridge = DisplayLinkBridge { [weak self] in
            self?.displayTick &+= 1
        }
        let link = screen.displayLink(target: bridge, selector: #selector(DisplayLinkBridge.fire))
        // Native refresh (60-120 Hz) on a busy MainActor (event-tap callbacks
        // + SwiftUI reconciliation) ate enough MainActor time to drop the
        // perf-test harness from its target 160 Hz combined event rate to
        // ~40 Hz, even though individual callback latencies stayed great.
        // 15 Hz is more than the eye needs for HUD counter readouts and
        // keeps the per-tick view-eval cost out of the event-tap path.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10,
                                                        maximum: 30,
                                                        preferred: 15)
        link.add(to: .main, forMode: .common)
        displayLinkBridge = bridge
        displayLink = link
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkBridge = nil
    }

    func tick() {
        // displayTick now bumps from CADisplayLink at the screen refresh
        // rate (see startDisplayLink) — this 1 Hz timer is just for
        // pause-detection + countdown, decoupled from view refresh.
        if let last = lastInputAt,
           Date().timeIntervalSince(last) > pauseDetectThreshold {
            isPaused = true
            return
        }
        isPaused = false
        // Auto-unlock is opt-in. When off, the timer just decorates the HUD and
        // never closes the lock — the user controls exit via codeword or button.
        guard AppSettings.shared.autoUnlockEnabled else { return }
        if remainingSeconds > 0 {
            remainingSeconds -= 1
        } else {
            stopLock()
        }
    }
}
