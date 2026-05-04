import AppKit
import ApplicationServices

enum AccessibilityPermission {
    static var isGranted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func request() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    // Wipes the TCC entry for this app, re-prompts, and opens System Settings.
    // Useful when the Accessibility toggle is stuck or grayed out.
    static func resetAndRequest() {
        let bundleID = Bundle.main.bundleIdentifier ?? "bmako101.KeebLock"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "Accessibility", bundleID]
        try? proc.run()
        proc.waitUntilExit()
        request()
        openSystemSettings()
    }
}
