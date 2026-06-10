import AppKit
import Foundation
import os

// Structured logger. When `AppSettings.debugLoggingEnabled` is true, writes to:
//   - macOS Console (NSLog), and
//   - ~/Library/Logs/KeebLock/keeblock.log
// snapshot() captures full system state — call this from the Settings tab to get
// a self-contained dump to share for debugging.
enum DebugLog {

    static let logsDirectory: URL = {
        // FileManager.urls(for:.libraryDirectory, in:.userDomainMask) is documented
        // to return at least one URL on macOS, but a force-unwrap here would crash
        // the static init the first time anyone touches DebugLog. Fall back to the
        // home directory so a cosmetic-but-broken environment doesn't kill the app.
        let library = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
        let dir = library.appendingPathComponent("Logs/KeebLock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let logURL: URL = logsDirectory.appendingPathComponent("keeblock.log")

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Lock-protected mirror of the AppSettings values the logger needs.
    /// `log()` and the rotation check run on background queues (SoundPlayer's
    /// audioQueue calls log(); rotateIfNeeded runs on ioQueue), where reading
    /// the @MainActor `AppSettings.shared` directly would be an isolation
    /// violation. AppSettings pushes updates here from its didSet observers
    /// (and once at init) via `syncConfig`.
    private struct Config {
        var enabled = false
        var maxLogBytes = 5 * 1024 * 1024
    }
    private static let config = OSAllocatedUnfairLock(initialState: Config())

    static var isEnabled: Bool {
        config.withLock { $0.enabled }
    }

    /// Called by AppSettings whenever `debugLoggingEnabled` or
    /// `logFileMaxSizeMB` changes (and once at startup).
    static func syncConfig(enabled: Bool, maxSizeMB: Int) {
        config.withLock {
            $0.enabled = enabled
            $0.maxLogBytes = maxSizeMB * 1024 * 1024
        }
    }

    /// Writes to NSLog and the log file when the toggle is on. Silent when off.
    static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        guard isEnabled else { return }
        let tag = (file as NSString).lastPathComponent
        NSLog("[KeebLock] %@:%d %@", tag, line, message)
        appendLine("[\(isoFormatter.string(from: Date()))] \(tag):\(line) \(message)")
    }

    /// Force-write regardless of toggle (used by diagnostic snapshot).
    static func writeForced(_ block: String) {
        appendLine(block)
    }

    /// Rolling counter — every Nth append checks the file size and
    /// rotates if it's over the cap. Keeping the check off the hot path
    /// (per-keystroke logging is allowed) matters more than catching
    /// the overshoot to the byte.
    private static var appendCount: Int = 0
    private static let rotationCheckInterval = 64
    /// Set on the first append after launch. Without it, a log file that
    /// pre-existed with a wider mode (e.g. created by a build that
    /// pre-dates `restrictPermissions`, or whatever umask was in force)
    /// would never be tightened — `restrictPermissions` was only called
    /// at creation and rotation. One chmod per process is cheap; the
    /// alternative of chmod-per-line on the hot path is wasteful.
    private static var permissionsTightenedThisLaunch: Bool = false
    /// Serializes all file I/O and the `appendCount` / `permissionsTightened`
    /// state. `log()` is called from the event-tap callback (main) AND from
    /// SoundPlayer's `audioQueue`; without this, two threads could open
    /// separate FileHandles, both seek to the same end-of-file offset, and
    /// interleave their writes into corrupted log lines. async keeps the
    /// per-keystroke logging path off the disk write entirely.
    private static let ioQueue = DispatchQueue(label: "de.6bm.KeebLock.debuglog", qos: .utility)

    private static func appendLine(_ line: String) {
        let payload = line + "\n"
        guard let data = payload.data(using: .utf8) else { return }

        ioQueue.async {
            appendCount &+= 1
            if appendCount % rotationCheckInterval == 0 {
                rotateIfNeeded()
            }

            do {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    let handle = try FileHandle(forWritingTo: logURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    if !permissionsTightenedThisLaunch {
                        restrictPermissions(logURL)
                        permissionsTightenedThisLaunch = true
                    }
                } else {
                    try data.write(to: logURL)
                    restrictPermissions(logURL)
                    permissionsTightenedThisLaunch = true
                }
            } catch {
                // Debug logging must never crash the app. Failures still show in
                // NSLog (the line above), so we lose nothing by swallowing here.
            }
        }
    }

    /// Tighten the file mode to 0600 — the default umask gives 0644
    /// which is world-readable. The log can include frontmost-app names
    /// and audio-file paths; on a multi-user Mac neighbours have no
    /// business reading either. Failures are non-fatal: the file is
    /// already on disk, restricting just hardens it.
    private static func restrictPermissions(_ url: URL) {
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: url.path
        )
    }

    /// Rotate the log if it has grown past the user-configured cap.
    /// Renames the current file to `keeblock.log.old` (replacing any
    /// previous backup), so one full window of history is always
    /// retained. Returns silently on any I/O failure — same fail-quiet
    /// principle as `appendLine`.
    private static func rotateIfNeeded() {
        // Runs on ioQueue — read the cap from the lock-protected mirror,
        // not from the @MainActor AppSettings.
        let maxBytes = config.withLock { $0.maxLogBytes }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > maxBytes else { return }
        let backup = logsDirectory.appendingPathComponent("keeblock.log.old")
        try? FileManager.default.removeItem(at: backup)
        do {
            try FileManager.default.moveItem(at: logURL, to: backup)
            restrictPermissions(backup)
            // Marker line in the fresh file — handy when reading two
            // halves of a long-running session.
            let marker = "[\(isoFormatter.string(from: Date()))] DebugLog rotated — previous \(size / 1024 / 1024) MB archived to keeblock.log.old\n"
            try? marker.data(using: .utf8)?.write(to: logURL)
            restrictPermissions(logURL)
            NSLog("[KeebLock] DebugLog: rotated %dMB → keeblock.log.old", size / 1024 / 1024)
        } catch {
            // Couldn't rotate — keep writing to the existing file, the
            // cap will just be exceeded for now. Better than losing
            // log data on a transient FS error.
        }
    }

    static func revealLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    // MARK: - Snapshot

    @MainActor
    static func snapshot() -> String {
        var lines: [String] = []

        lines.append("============ KeebLock Diagnostic Snapshot ============")
        lines.append("Time:      \(isoFormatter.string(from: Date()))")
        lines.append("App:       \(Bundle.main.keeblockVersionString)  ·  \(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("System:    \(ProcessInfo.processInfo.operatingSystemVersionString)  ·  \(machineArch())  ·  PID \(ProcessInfo.processInfo.processIdentifier)")
        lines.append("Memory:    \(memoryReport())")
        lines.append("Frontmost: \(frontmostAppDescription())")
        lines.append("")

        let s = AppSettings.shared
        lines.append("------ Settings ------")
        lines.append("codeword:       \(s.codeword.count) chars (content not logged)")
        lines.append("duration:       \(s.durationMinutes) min")
        lines.append("sound:          \(s.soundEnabled ? "on  vol=\(Int(s.soundVolume * 100))%  source=\(s.soundFileDisplayName ?? "synth click")" : "off")")
        lines.append("effect:         \(s.effectEnabled ? "on  \(s.screenEffect.rawValue)  count=\(s.sparkCount)" : "off")")
        lines.append("pixel grid:     cellsPerAxis=\(s.cellsPerAxis) (fineness \(s.pixelFineness)/10)")
        lines.append("colors:         bg=\(s.backgroundColor.rawValue)  pixel=\(s.pixelColor.rawValue)")
        lines.append("debug logging:  \(s.debugLoggingEnabled ? "on" : "off")")
        lines.append("")

        let screens = NSScreen.screens
        let mainIdx = (NSScreen.main ?? screens.first).flatMap { screens.firstIndex(of: $0) } ?? -1
        lines.append("------ Screens (\(screens.count), main=\(mainIdx)) ------")
        for (i, sc) in screens.enumerated() {
            lines.append("  [\(i)] \(Int(sc.frame.width))×\(Int(sc.frame.height)) @ \(sc.backingScaleFactor)x  origin=(\(Int(sc.frame.minX)),\(Int(sc.frame.minY)))  \(sc.colorSpace?.localizedName ?? "?")  \(sc.maximumFramesPerSecond)Hz")
        }
        lines.append("")
        lines.append(asciiScreenLayout(screens))
        lines.append("")

        let c = LockController.shared
        lines.append("------ Lock state ------")
        lines.append("locked:          \(c.isLocked ? "true" : "false")\(c.isPaused ? " (paused)" : "")")
        lines.append("auto-unlock:     \(c.totalSeconds > 0 ? "\(formatTime(c.remainingSeconds)) / \(formatTime(c.totalSeconds))" : "—")")
        lines.append("windows:         \(c.lockWindowCount) (level=screenSaver, stationary, canJoinAllSpaces)")
        lines.append("event tap:       \(c.eventTapInstalled ? "active (cgSession, headInsert)" : "inactive")")
        lines.append("space observer:  \(c.spaceObserverInstalled ? "active" : "inactive")")
        lines.append("")
        lines.append("------ Input counters ------")
        lines.append("wipes:           \(c.keystrokeCount)  → letters=\(c.letterCount)  numbers=\(c.numberCount)  symbols=\(c.symbolCount)  control=\(c.controlKeyCount)  function=\(c.functionKeyCount)  media=\(c.mediaKeyCount)")
        lines.append("mouse clicks:    L=\(c.leftClickCount)  R=\(c.rightClickCount)  M=\(c.middleClickCount)  back=\(c.backClickCount)  fwd=\(c.forwardClickCount)")
        lines.append("scroll bursts:   \(c.scrollCount)")
        lines.append("gestures:        swipes=\(c.swipeCount)  pinch=\(c.pinchCount)  rotate=\(c.rotateCount)")
        lines.append("cleanmap session: \(c.sessionKeyCounts.count) keys / \(c.sessionKeyCounts.values.reduce(0, +)) wipes")
        lines.append("cleanmap overall: \(c.overallKeyCounts.count) keys / \(c.overallKeyCounts.values.reduce(0, +)) wipes (persisted)")
        lines.append("")

        let states = c.screenWipeStates
        if !states.isEmpty {
            lines.append("------ Screen wipe state ------")
            for (idx, st) in states.enumerated() {
                let pct = st.totalCells > 0
                    ? Double(st.wipedCells) / Double(st.totalCells) * 100.0
                    : 0.0
                lines.append(
                    "  [\(idx)] \(Int(st.frame.width))×\(Int(st.frame.height))  stage \(st.stage)  \(st.cellsW)×\(st.cellsH) cells  wiped \(st.wipedCells)/\(st.totalCells) (\(String(format: "%.1f", pct))%)  intact=\(st.intactCells)"
                )
            }
            lines.append("")
        }
        lines.append("------ Subsystems ------")
        lines.append("audio engine:    \(c.soundDiagnostic)")
        lines.append("accessibility:   \(AccessibilityPermission.isGranted ? "granted" : "denied")")
        lines.append("")
        lines.append(contentsOf: PerfMetrics.shared.snapshotLines())
        lines.append("verbose perf:    \(s.verbosePerfEnabled ? "on (latency sampling active)" : "off (only aggregate counters)")")
        lines.append("")

        let events = PerfMetrics.shared.eventLines()
        if !events.isEmpty {
            lines.append("------ Recent Events (last \(events.count), oldest first) ------")
            lines.append(contentsOf: events)
            lines.append("")
        }

        lines.append("============ end snapshot ============")
        return lines.joined(separator: "\n")
    }

    private static func frontmostAppDescription() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "?" }
        let name = app.localizedName ?? app.bundleIdentifier ?? "?"
        return "\(name) (\(app.bundleIdentifier ?? "?"))"
    }

    private static func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: - Helpers

    /// `arm64` / `x86_64` / `?`. Public so panel views can reuse it instead
    /// of duplicating the uname dance.
    static func machineArch() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "?" }
        }
    }

    private static func memoryReport() -> String {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return "?" }
        let mb = Double(info.resident_size) / 1024 / 1024
        return String(format: "%.1f MB resident", mb)
    }

    /// Tiny ASCII map of screen positions, normalized to fit ~60 columns.
    private static func asciiScreenLayout(_ screens: [NSScreen]) -> String {
        guard !screens.isEmpty else { return "(no screens)" }
        let allFrames = screens.map(\.frame)
        let minX = allFrames.map(\.minX).min() ?? 0
        let minY = allFrames.map(\.minY).min() ?? 0
        let maxX = allFrames.map(\.maxX).max() ?? 1
        let maxY = allFrames.map(\.maxY).max() ?? 1
        let totalW = max(1, maxX - minX)
        let totalH = max(1, maxY - minY)

        let cols = 60
        let rows = 12
        let scaleX = Double(cols) / Double(totalW)
        let scaleY = Double(rows) / Double(totalH)

        var grid = Array(repeating: Array(repeating: Character(" "), count: cols + 1), count: rows + 1)

        for (i, frame) in allFrames.enumerated() {
            let x0 = Int((frame.minX - minX) * scaleX)
            let x1 = Int((frame.maxX - minX) * scaleX)
            // y axis flip — our ASCII reads top-down, AppKit is bottom-up
            let y0 = rows - Int((frame.maxY - minY) * scaleY)
            let y1 = rows - Int((frame.minY - minY) * scaleY)

            let label: Character = "\(i)".first ?? "?"
            for y in max(0, y0)...min(rows, y1) {
                for x in max(0, x0)...min(cols, x1) {
                    if y == y0 || y == y1 || x == x0 || x == x1 {
                        grid[y][x] = "█"
                    } else if grid[y][x] == " " {
                        grid[y][x] = "·"
                    }
                }
            }
            // place index label centred in the rect
            let cy = max(0, min(rows, (y0 + y1) / 2))
            let cx = max(0, min(cols, (x0 + x1) / 2))
            grid[cy][cx] = label
        }
        let body = grid.map { String($0) }.joined(separator: "\n")
        return "------ Screen layout ------\n\(body)\n(0,0 in this map = upper-left of the bounding box)"
    }
}

extension Bundle {
    /// "1.0 (1)"-style display string used by Settings, the live debug
    /// panel, and the diagnostic snapshot. One source of truth.
    var keeblockVersionString: String {
        let v = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }
}
