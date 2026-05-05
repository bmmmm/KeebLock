import AppKit
import Foundation

// Structured logger. When `AppSettings.debugLoggingEnabled` is true, writes to:
//   - macOS Console (NSLog), and
//   - ~/Library/Logs/KeebLock/keeblock.log
// snapshot() captures full system state — call this from the Settings tab to get
// a self-contained dump to share for debugging.
enum DebugLog {

    static let logsDirectory: URL = {
        let dir = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Logs/KeebLock", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let logURL: URL = logsDirectory.appendingPathComponent("keeblock.log")

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static var isEnabled: Bool {
        AppSettings.shared.debugLoggingEnabled
    }

    /// Always writes to NSLog; only writes to the log file when toggle is on.
    static func log(_ message: String, file: String = #fileID, line: Int = #line) {
        let tag = (file as NSString).lastPathComponent
        NSLog("[KeebLock] %@:%d %@", tag, line, message)
        guard isEnabled else { return }
        appendLine("[\(isoFormatter.string(from: Date()))] \(tag):\(line) \(message)")
    }

    /// Force-write regardless of toggle (used by diagnostic snapshot).
    static func writeForced(_ block: String) {
        appendLine(block)
    }

    private static func appendLine(_ line: String) {
        let payload = line + "\n"
        guard let data = payload.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                defer { _ = try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                return
            }
        }
        try? data.write(to: logURL)
    }

    static func revealLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    // MARK: - Snapshot

    @MainActor
    static func snapshot() -> String {
        var lines: [String] = []
        lines.append("============ KeebLock Diagnostic Snapshot ============")
        lines.append("Time: \(isoFormatter.string(from: Date()))")
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines.append("App version: \(v) (\(b))")
        lines.append("Bundle ID:   \(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("macOS:       \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Arch:        \(machineArch())")
        lines.append("PID:         \(ProcessInfo.processInfo.processIdentifier)")
        lines.append("Locale:      \(Locale.current.identifier)")
        lines.append("Timezone:    \(TimeZone.current.identifier)")
        lines.append("Memory:      \(memoryReport())")
        lines.append("Uptime:      \(processUptimeString())")
        lines.append("")

        let s = AppSettings.shared
        lines.append("------ Settings ------")
        lines.append("codeword length:   \(s.codeword.count)  (content not logged)")
        lines.append("durationMinutes:   \(s.durationMinutes)")
        lines.append("soundEnabled:      \(s.soundEnabled)")
        lines.append("soundVolume:       \(String(format: "%.2f", s.soundVolume))")
        lines.append("soundFile:         \(s.soundFileDisplayName ?? "synth click (default)")")
        lines.append("sound dispatch:    async (event-tap non-blocking)")
        lines.append("effectEnabled:     \(s.effectEnabled)")
        lines.append("screenEffect:      \(s.screenEffect.rawValue)")
        lines.append("sparkCount:        \(s.sparkCount)")
        lines.append("pixelFineness:     \(s.pixelFineness) → cellsPerAxis=\(s.cellsPerAxis)")
        lines.append("backgroundColor:   \(s.backgroundColor.rawValue)")
        lines.append("pixelColor:        \(s.pixelColor.rawValue)")
        lines.append("debugLogging:      \(s.debugLoggingEnabled)")
        lines.append("")

        let screens = NSScreen.screens
        lines.append("------ Screens (\(screens.count)) ------")
        for (i, sc) in screens.enumerated() {
            lines.append("  [\(i)] frame=\(NSStringFromRect(sc.frame))")
            lines.append("       visibleFrame=\(NSStringFromRect(sc.visibleFrame))")
            lines.append("       backingScale=\(sc.backingScaleFactor)")
            lines.append("       colorSpace=\(sc.colorSpace?.localizedName ?? "?")")
            lines.append("       maxFPS=\(sc.maximumFramesPerSecond)")
        }
        lines.append("Main screen index: \(screens.firstIndex(of: NSScreen.main ?? screens[0]) ?? -1)")
        lines.append("")
        lines.append(asciiScreenLayout(screens))
        lines.append("")

        let c = LockController.shared
        lines.append("------ Lock state ------")
        lines.append("isLocked:          \(c.isLocked)")
        lines.append("isPaused:          \(c.isPaused)")
        lines.append("keystrokeCount:    \(c.keystrokeCount)")
        lines.append("remainingSeconds:  \(c.remainingSeconds) / \(c.totalSeconds)")
        lines.append("currentCodeword:   \(c.currentCodeword.count) chars")
        lines.append("sparkTrigger:      \(c.sparkTrigger)")
        lines.append("keyCounts:         \(c.keyCounts.count) distinct, \(c.keyCounts.values.reduce(0, +)) total presses")
        lines.append("keyboard:          letters=\(c.letterCount) numbers=\(c.numberCount) function=\(c.fnKeyCount) system=\(c.mediaKeyCount) other=\(c.otherKeyCount)")
        lines.append("mouse:             left=\(c.leftClickCount) right=\(c.rightClickCount) middle=\(c.middleClickCount) back=\(c.backClickCount) forward=\(c.forwardClickCount) scroll=\(c.scrollCount)")
        lines.append("gestures:          spaces=\(c.spaceSwitchCount)")
        lines.append("missClicks:        \(c.missClickCount) (everything except letters/numbers)")
        lines.append("")
        lines.append("------ Audio engine ------")
        lines.append("engine status:     \(c.soundDiagnostic)")
        lines.append("")

        lines.append("------ Permissions ------")
        lines.append("Accessibility: \(AccessibilityPermission.isGranted ? "granted" : "denied")")
        lines.append("")

        lines.append("============ end snapshot ============")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func machineArch() -> String {
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

    private static func processUptimeString() -> String {
        let uptime = ProcessInfo.processInfo.systemUptime
        return String(format: "%.0fs since boot", uptime)
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
