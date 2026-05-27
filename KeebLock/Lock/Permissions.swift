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
    //
    // tccutil is normally <100 ms but used to run synchronously on the main
    // thread, briefly freezing the UI. Now spawned with a terminationHandler
    // so the click returns immediately and `completion` runs on MainActor
    // once the process has exited (or right away if we can't even launch it).
    static func resetAndRequest(completion: @escaping @MainActor () -> Void) {
        let finish: @MainActor () -> Void = {
            request()
            openSystemSettings()
            completion()
        }

        // Bundle.main.bundleIdentifier is nil only outside an app bundle
        // (e.g. running as a loose binary). In that state tccutil has nothing
        // to reset anyway, so just prompt + open Settings and let the user
        // recover manually.
        guard let bundleID = Bundle.main.bundleIdentifier else {
            DebugLog.log("Permissions.resetAndRequest: bundleIdentifier nil; skipping tccutil")
            Task { @MainActor in finish() }
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        proc.arguments = ["reset", "Accessibility", bundleID]
        proc.terminationHandler = { p in
            if p.terminationStatus != 0 {
                DebugLog.log("Permissions.resetAndRequest: tccutil exited with status \(p.terminationStatus)")
            }
            Task { @MainActor in finish() }
        }
        do {
            try proc.run()
        } catch {
            DebugLog.log("Permissions.resetAndRequest: tccutil launch failed: \(error.localizedDescription)")
            Task { @MainActor in finish() }
        }
    }
}
