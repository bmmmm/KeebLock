#if DEBUG
import AppKit
import CoreGraphics
import Foundation

/// Drives synthetic input into the lock loop for performance measurement.
///
/// Safety model:
///   - Synth keycodes are restricted to {0,1,2,3,4,5,8,9} which produce
///     characters "a s d f h g c v" on US/DE/most Latin layouts. The
///     test codeword (set by PerfTestRunner) is a digit-only string,
///     so the matcher structurally cannot reach a match from any of
///     these chars and cannot end the lock prematurely.
///   - Mode B (real CGEvent.post) is pre-flighted: each injection
///     verifies the lock is still active and the tap is installed.
///     If either fails the test aborts immediately rather than
///     leaking keystrokes — or, for mousekeymix, real cursor warps —
///     into the foreground app.
///   - Both modes poll a kill-file every iteration. Removing the file
///     externally (Claude via `rm`) aborts cleanly.
@MainActor
final class PerfTestHarness {
    let suite: PerfTestArgs.Suite
    let mode: PerfTestArgs.Mode
    let killFilePath: String

    private(set) var startedAt: Date = .distantPast
    private(set) var injectedCount: Int = 0
    private(set) var abortedReason: String?

    /// Keycodes "a s d f h g c v" — printable chars that exist on
    /// every common Latin layout, none of which appear in the
    /// digit-only test codeword.
    private static let synthKeycodes: [UInt16] = [0, 1, 2, 3, 4, 5, 8, 9]

    init(suite: PerfTestArgs.Suite, mode: PerfTestArgs.Mode, killFilePath: String) {
        self.suite = suite
        self.mode = mode
        self.killFilePath = killFilePath
    }

    /// Total events the suite plans to inject (key + mouse for mousekeymix).
    /// PerfTestRunner reads this for the snapshot's `totalEventsRequested`
    /// field; the actual injected count lands in `injectedCount`.
    var totalEvents: Int {
        switch suite {
        case .burst:        return 500
        case .saveStorm:    return 1000
        case .mouseKeyMix:  return mouseKeyMixKeyEvents + mouseKeyMixMouseEvents
        }
    }

    // mousekeymix targets: 10 s window, ~160 Hz combined load.
    private let mouseKeyMixKeyEvents = 1000        // 100 Hz × 10 s
    private let mouseKeyMixMouseEvents = 600       // 60 Hz × 10 s
    private let mouseKeyMixKeyIntervalNs: UInt64 = 10_000_000    // 100 Hz
    private let mouseKeyMixMouseIntervalNs: UInt64 = 16_666_666  // 60 Hz

    /// Per-event pacing for the single-stream suites. Burst targets ~100 keys/s
    /// to mimic a fast typist. saveStorm packs them tighter to maximise pressure
    /// on the throttled UserDefaults write at the wipe-stride boundary.
    private var intervalNs: UInt64 {
        switch suite {
        case .burst:        return 10_000_000  // 10 ms → 100 Hz
        case .saveStorm:    return  2_000_000  //  2 ms → 500 Hz
        case .mouseKeyMix:  return 0           // unused — two parallel streams
        }
    }

    func run() async {
        startedAt = Date()
        DebugLog.log("perf-test: harness start suite=\(suite.rawValue) mode=\(mode.rawValue) total=\(totalEvents)")

        switch suite {
        case .burst, .saveStorm:
            await runKeyOnly()
        case .mouseKeyMix:
            await runMouseKeyMix()
        }

        DebugLog.log("perf-test: harness done — injected=\(injectedCount)/\(totalEvents)")
    }

    // MARK: - Single-stream suites (burst, saveStorm)

    private func runKeyOnly() async {
        let count = totalEvents
        let interval = intervalNs
        for i in 0..<count {
            if let reason = abortCheck() {
                abortedReason = reason
                DebugLog.log("perf-test: ABORT @ event \(i)/\(count) — \(reason)")
                return
            }
            let kc = Self.synthKeycodes[i % Self.synthKeycodes.count]
            injectKeyDown(keycode: kc)
            injectedCount = i + 1
            // Sleep for pacing. Task.sleep yields the MainActor so the
            // event tap callback (which also runs on MainActor in mode A)
            // can drain its work between iterations.
            try? await Task.sleep(nanoseconds: interval)
        }
    }

    // MARK: - Mixed key + mouse suite

    /// Runs the two streams concurrently on the same MainActor — each
    /// `Task.sleep` yields, letting the other stream advance, so the lock
    /// callback sees an interleaved key/mouse load like a real user typing
    /// while moving the cursor. Combined rate lands around 160 Hz, which
    /// is the bottom of the band where hypothesis A predicts MainActor
    /// saturation.
    private func runMouseKeyMix() async {
        async let keyStream: Void = runMouseKeyMixKeyStream()
        async let mouseStream: Void = runMouseKeyMixMouseStream()
        _ = await (keyStream, mouseStream)
    }

    private func runMouseKeyMixKeyStream() async {
        for i in 0..<mouseKeyMixKeyEvents {
            if let reason = abortCheck() {
                abortedReason = reason
                DebugLog.log("perf-test: ABORT key stream @ \(i)/\(mouseKeyMixKeyEvents) — \(reason)")
                return
            }
            let kc = Self.synthKeycodes[i % Self.synthKeycodes.count]
            injectKeyDown(keycode: kc)
            injectedCount &+= 1
            try? await Task.sleep(nanoseconds: mouseKeyMixKeyIntervalNs)
        }
    }

    private func runMouseKeyMixMouseStream() async {
        let path = mousePath(steps: mouseKeyMixMouseEvents)
        for (i, point) in path.enumerated() {
            if let reason = abortCheck() {
                abortedReason = reason
                DebugLog.log("perf-test: ABORT mouse stream @ \(i)/\(mouseKeyMixMouseEvents) — \(reason)")
                return
            }
            injectMouseMoved(at: point)
            injectedCount &+= 1
            try? await Task.sleep(nanoseconds: mouseKeyMixMouseIntervalNs)
        }
    }

    /// Sine-wave horizontal sweep across the main screen at the vertical
    /// midpoint. Deterministic so any cursor warp in the resulting data
    /// stands out against the smooth seeded trajectory — if the user sees
    /// `cursor=(x,y)` deltas that don't follow the sine, that's a WindowServer
    /// warp, not seeded movement.
    private func mousePath(steps: Int) -> [CGPoint] {
        guard let screen = NSScreen.main else {
            return Array(repeating: CGPoint(x: 100, y: 100), count: steps)
        }
        let bounds = screen.frame
        let baseX = bounds.midX
        let baseY = bounds.midY
        let amplitude = max(100, (bounds.width - 400) / 2)
        let periodSeconds: Double = 2.0
        var points: [CGPoint] = []
        points.reserveCapacity(steps)
        for i in 0..<steps {
            // i / 60 → seconds, matching the 60 Hz pacing.
            let t = Double(i) / 60.0
            let x = baseX + amplitude * sin(t * 2 * .pi / periodSeconds)
            points.append(CGPoint(x: x, y: baseY))
        }
        return points
    }

    // MARK: - Injection

    private func injectKeyDown(keycode: UInt16) {
        switch mode {
        case .directInject:
            guard let event = CGEvent(keyboardEventSource: nil,
                                      virtualKey: keycode,
                                      keyDown: true) else { return }
            LockController.shared._testInjectEvent(event, type: .keyDown)

        case .realOSPost:
            // Belt-and-braces: never post a synthetic event into the OS
            // stream unless our lock is demonstrably swallowing input.
            // Without this guard a failed lock-window installation would
            // turn the harness into a keylogger for the focused app.
            guard LockController.shared.isLocked,
                  LockController.shared.eventTapInstalled else {
                abortedReason = "lock or tap inactive"
                return
            }
            guard let event = CGEvent(keyboardEventSource: nil,
                                      virtualKey: keycode,
                                      keyDown: true) else { return }
            event.post(tap: .cghidEventTap)
        }
    }

    private func injectMouseMoved(at point: CGPoint) {
        switch mode {
        case .directInject:
            guard let event = CGEvent(mouseEventSource: nil,
                                      mouseType: .mouseMoved,
                                      mouseCursorPosition: point,
                                      mouseButton: .left) else { return }
            LockController.shared._testInjectEvent(event, type: .mouseMoved)

        case .realOSPost:
            // Mode B for mousekeymix is even more dangerous than for keys —
            // a synthetic mouseMoved that escapes the lock window would
            // warp the real cursor across screens. Same pre-flight as
            // keys; lock+tap must both be live or we bail.
            guard LockController.shared.isLocked,
                  LockController.shared.eventTapInstalled else {
                abortedReason = "lock or tap inactive"
                return
            }
            guard let event = CGEvent(mouseEventSource: nil,
                                      mouseType: .mouseMoved,
                                      mouseCursorPosition: point,
                                      mouseButton: .left) else { return }
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Abort checks

    private func abortCheck() -> String? {
        if !FileManager.default.fileExists(atPath: killFilePath) {
            return "kill-file removed"
        }
        if mode == .realOSPost {
            if !LockController.shared.isLocked    { return "lock dropped mid-test" }
            if !LockController.shared.eventTapInstalled { return "tap dropped mid-test" }
        }
        return nil
    }
}
#endif
