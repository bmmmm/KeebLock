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
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                return
            }
        }
        try? data.write(to: logURL)
    }

    // MARK: - Snapshot

    @MainActor
    static func snapshot() -> String {
        var lines: [String] = []
        lines.append("=== KeebLock Diagnostic Snapshot ===")
        lines.append("Time: \(isoFormatter.string(from: Date()))")
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        lines.append("App version: \(v) (\(b))")
        lines.append("Bundle ID: \(Bundle.main.bundleIdentifier ?? "?")")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        let arch = ProcessInfo.processInfo.environment["CARCH"] ?? machineArch()
        lines.append("Arch: \(arch)")
        lines.append("")

        let s = AppSettings.shared
        lines.append("--- Settings ---")
        lines.append("codeword length:   \(s.codeword.count)  (content not logged for privacy)")
        lines.append("durationMinutes:   \(s.durationMinutes)")
        lines.append("soundEnabled:      \(s.soundEnabled)")
        lines.append("sparksEnabled:     \(s.sparksEnabled)")
        lines.append("pixelFineness:     \(s.pixelFineness) → cellsPerAxis=\(s.cellsPerAxis)")
        lines.append("customScreenColor: \(s.customScreenColorRGB.map { "\($0)" } ?? "nil (random per stage)")")
        lines.append("debugLogging:      \(s.debugLoggingEnabled)")
        lines.append("")

        let screens = NSScreen.screens
        lines.append("--- Screens (\(screens.count)) ---")
        for (i, sc) in screens.enumerated() {
            lines.append("  [\(i)] frame=\(NSStringFromRect(sc.frame))")
            lines.append("       visibleFrame=\(NSStringFromRect(sc.visibleFrame))")
            lines.append("       backingScale=\(sc.backingScaleFactor)")
            lines.append("       colorSpace=\(sc.colorSpace?.localizedName ?? "?")")
            lines.append("       maxFPS=\(sc.maximumFramesPerSecond)")
        }
        lines.append("Main screen index: \(screens.firstIndex(of: NSScreen.main ?? screens[0]) ?? -1)")
        lines.append("")

        let c = LockController.shared
        lines.append("--- Lock state ---")
        lines.append("isLocked:           \(c.isLocked)")
        lines.append("isPaused:           \(c.isPaused)")
        lines.append("keystrokeCount:     \(c.keystrokeCount)")
        lines.append("remainingSeconds:   \(c.remainingSeconds) / \(c.totalSeconds)")
        lines.append("currentCodewordLen: \(c.currentCodeword.count)")
        lines.append("sparkTrigger:       \(c.sparkTrigger)")
        lines.append("keyCounts:          \(c.keyCounts.count) distinct keys, \(c.keyCounts.values.reduce(0, +)) total presses")
        lines.append("")

        lines.append("--- Permissions ---")
        lines.append("Accessibility granted: \(AccessibilityPermission.isGranted)")
        lines.append("")

        lines.append("=== end snapshot ===")
        return lines.joined(separator: "\n")
    }

    static func revealLogInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([logURL])
    }

    private static func machineArch() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let machine = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "?" }
        }
        return machine
    }
}
