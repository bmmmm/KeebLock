#if DEBUG
import AppKit
import Foundation

/// Top-level orchestrator for `--perf-test`. Sets the lock up with a
/// digit-only codeword the harness can never accidentally type, schedules
/// a hard timeout that forces shutdown regardless of harness state, runs
/// the chosen suite, snapshots PerfMetrics into JSON, and terminates.
///
/// Safety layers (in order, defence in depth):
///   1. Codeword chosen so the synth keystrokes structurally cannot match.
///   2. Kill-file at $TMPDIR/keeblock-perf-test.lock — `rm` aborts cleanly.
///   3. DispatchSourceTimer hard-timeout (30 s) calls stopLock() and exits
///      regardless of what the harness coroutine is doing.
///   4. Mode B pre-flights every CGEvent.post against isLocked/eventTapInstalled.
///   5. App was launched with `--perf-test`, so the normal UI window
///      was suppressed; nothing else in the app is interactive.
@MainActor
enum PerfTestRunner {
    /// Set true while the harness is driving synthetic input. Read by
    /// LockController.checkAnyEventCursorJump to suppress the auto-
    /// snapshot trigger — synthetic key/mouse events have unrelated
    /// `event.location` values that legitimately produce 500+ px deltas
    /// between consecutive events, which would otherwise machine-gun
    /// inline snapshots and pollute the latency measurement we're
    /// trying to take.
    @MainActor static private(set) var isRunning: Bool = false

    private static let killFileName = "keeblock-perf-test.lock"
    /// Hard ceiling for the entire test, including warmup + harness +
    /// snapshot write. burst takes ~5 s, saveStorm ~2 s; 30 s is
    /// comfortable headroom and well below any sensible "I forgot the
    /// test is running" window.
    private static let hardTimeoutSeconds: Int = 30
    /// Codeword is all-digits so synth Latin letters cannot form it.
    /// Length is irrelevant for safety; chosen long enough that the
    /// in-lock match progress display has room to render.
    private static let testCodeword = "1234567890"

    static func run(args: PerfTestArgs) async {
        let killFile = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent(killFileName)

        DebugLog.log("perf-test: starting suite=\(args.suite.rawValue) mode=\(args.mode.rawValue) output=\(args.outputPath)")

        // Surface the harness flag so the lock loop's cursor-jump
        // auto-snapshot stays out of the measurement.
        Self.isRunning = true
        defer { Self.isRunning = false }

        // 1) Write kill-file so external `rm` is the abort mechanism.
        FileManager.default.createFile(atPath: killFile, contents: Data("running\n".utf8))
        defer { try? FileManager.default.removeItem(atPath: killFile) }

        // 2) Hard timeout — single source of truth for "this test is over".
        //    Fires even if the harness coroutine is wedged, the lock failed
        //    to install, or anything else went sideways.
        let timeoutTimer = DispatchSource.makeTimerSource(queue: .main)
        timeoutTimer.schedule(deadline: .now() + .seconds(hardTimeoutSeconds))
        timeoutTimer.setEventHandler {
            DebugLog.log("perf-test: HARD TIMEOUT reached — forcing teardown")
            forceTeardown(outputPath: args.outputPath,
                          args: args,
                          reason: "hard-timeout")
        }
        timeoutTimer.resume()

        // 3) Enable verbose perf so the latency ring fills. Restore on exit
        //    so we don't pollute the user's settings across test runs.
        let settings = AppSettings.shared
        let savedVerbose = settings.verbosePerfEnabled
        settings.verbosePerfEnabled = true
        defer { settings.verbosePerfEnabled = savedVerbose }

        // 4) Permission check — bail with a useful message if the user
        //    hasn't granted Accessibility yet. CGEventTap silently fails
        //    without it; the harness would inject keys into a non-lock
        //    surface.
        guard AccessibilityPermission.isGranted else {
            DebugLog.log("perf-test: FATAL — Accessibility permission missing; cannot install event tap")
            writeErrorJSON(to: args.outputPath, args: args, reason: "no-accessibility")
            timeoutTimer.cancel()
            NSApp.terminate(nil)
            return
        }

        // 5) Start the lock. durationMinutes=1 → totalSeconds clamps to 60,
        //    which is well above our hard timeout. The lock controller
        //    decides on its own whether to auto-tick down based on the
        //    user's AppSettings.autoUnlockEnabled; the hard timeout above
        //    is what actually ends the test, so it doesn't matter either way.
        let controller = LockController.shared
        controller.startLock(codeword: testCodeword, durationMinutes: 1)
        guard controller.isLocked else {
            DebugLog.log("perf-test: FATAL — startLock returned without locking")
            writeErrorJSON(to: args.outputPath, args: args, reason: "lock-not-started")
            timeoutTimer.cancel()
            NSApp.terminate(nil)
            return
        }

        // 6) Warmup. The lock controller has a warmupGracePeriod of 0.7 s
        //    during which non-keyboard events are swallowed without
        //    counting. Keyboard isn't gated but we still want the windows,
        //    Metal renderers, and tap to settle before measurement starts.
        DebugLog.log("perf-test: warmup 1.5s")
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // 7) Run the chosen harness. Both modes are async-friendly — they
        //    yield the MainActor between injections so the event tap's
        //    callback (which runs on this same actor) can drain.
        PerfMetrics.shared.reset()  // discard warmup-window noise
        PerfMetrics.shared.sessionStart()  // restart timing window
        let harnessStart = Date()
        let harness = PerfTestHarness(
            suite: args.suite,
            mode: args.mode,
            killFilePath: killFile
        )
        await harness.run()
        let durationMs = Int(Date().timeIntervalSince(harnessStart) * 1000)

        // 8) Brief drain so any async wipe-dispatch / SwiftUI work
        //    completes before we snapshot.
        try? await Task.sleep(nanoseconds: 300_000_000)

        // 9) Snapshot + write JSON.
        writeSnapshotJSON(
            to: args.outputPath,
            args: args,
            durationMs: durationMs,
            harness: harness
        )

        // 10) Tear down — stop the lock cleanly, cancel the timer, exit.
        controller.stopLock()
        try? await Task.sleep(nanoseconds: 200_000_000)
        timeoutTimer.cancel()
        DebugLog.log("perf-test: done — exiting")
        NSApp.terminate(nil)
    }

    // MARK: - JSON writers

    private static func writeSnapshotJSON(to path: String,
                                          args: PerfTestArgs,
                                          durationMs: Int,
                                          harness: PerfTestHarness) {
        let snapshot = PerfMetrics.shared.perfTestSnapshot(
            suite: args.suite.rawValue,
            mode: args.mode.rawValue,
            durationMs: durationMs,
            totalEventsRequested: harness.totalEvents,
            cellsPerAxis: AppSettings.shared.cellsPerAxis,
            screenCount: NSScreen.screens.count,
            wipeMode: AppSettings.shared.wipeMode.rawValue
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(snapshot)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            DebugLog.log("perf-test: snapshot written to \(path) (\(data.count) bytes)")
        } catch {
            DebugLog.log("perf-test: snapshot write FAILED — \(error.localizedDescription)")
        }
    }

    private static func writeErrorJSON(to path: String,
                                       args: PerfTestArgs,
                                       reason: String) {
        let payload: [String: String] = [
            "error": reason,
            "suite": args.suite.rawValue,
            "mode": args.mode.rawValue,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    // MARK: - Hard teardown

    /// Called from the timeout timer's handler. Tries to write whatever
    /// snapshot we can, then forces app exit. The defer chain in run()
    /// won't fire if we exit here, but the kill-file removal is a
    /// best-effort cleanup the next test run will overwrite anyway.
    private static func forceTeardown(outputPath: String,
                                      args: PerfTestArgs,
                                      reason: String) {
        let snapshot = PerfMetrics.shared.perfTestSnapshot(
            suite: args.suite.rawValue,
            mode: args.mode.rawValue,
            durationMs: 0,
            totalEventsRequested: 0,
            cellsPerAxis: AppSettings.shared.cellsPerAxis,
            screenCount: NSScreen.screens.count,
            wipeMode: AppSettings.shared.wipeMode.rawValue
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }
        LockController.shared.stopLock()
        DebugLog.log("perf-test: hard teardown — \(reason)")
        exit(2)
    }
}
#endif
