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
///     leaking keystrokes into the foreground app.
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

    var totalEvents: Int {
        switch suite {
        case .burst:     return 500
        case .saveStorm: return 1000
        }
    }

    /// Per-event pacing. Burst targets ~100 keys/s to mimic a fast typist.
    /// saveStorm packs them tighter to maximise pressure on the throttled
    /// UserDefaults write at the wipe-stride boundary.
    private var intervalNs: UInt64 {
        switch suite {
        case .burst:     return 10_000_000  // 10 ms → 100 Hz
        case .saveStorm: return  2_000_000  //  2 ms → 500 Hz
        }
    }

    func run() async {
        startedAt = Date()
        DebugLog.log("perf-test: harness start suite=\(suite.rawValue) mode=\(mode.rawValue) total=\(totalEvents) interval=\(intervalNs/1_000_000)ms")

        for i in 0..<totalEvents {
            if let reason = abortCheck() {
                abortedReason = reason
                DebugLog.log("perf-test: ABORT @ event \(i)/\(totalEvents) — \(reason)")
                return
            }

            let kc = Self.synthKeycodes[i % Self.synthKeycodes.count]
            injectKeyDown(keycode: kc)
            injectedCount = i + 1

            // Sleep for pacing. Task.sleep yields the MainActor so the
            // event tap callback (which also runs on MainActor in mode A)
            // can drain its work between iterations.
            try? await Task.sleep(nanoseconds: intervalNs)
        }
        DebugLog.log("perf-test: harness done — injected=\(injectedCount)/\(totalEvents)")
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
