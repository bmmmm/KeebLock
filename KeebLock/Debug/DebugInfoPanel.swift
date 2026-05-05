import AppKit
import Combine
import SwiftUI

// Live debug overlay shown in the Settings tab when AppSettings.debugLoggingEnabled
// is true. Refreshes once per second so screens, lock state and counts stay current.
struct DebugInfoPanel: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: LockController

    @State private var screens: [NSScreen] = NSScreen.screens
    @State private var tick: Int = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "ladybug.fill")
                Text("Live debug").font(.caption.weight(.semibold))
                Spacer()
                Text("refresh \(tick)").font(.caption2).foregroundStyle(.secondary)
            }
            .foregroundStyle(.orange)

            // App + system
            row("App",          appVersion())
            row("macOS",        ProcessInfo.processInfo.operatingSystemVersionString + " · " + machineArch())
            row("Frontmost",    NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")

            Divider().padding(.vertical, 2)

            // Screens
            row("Screens",      "\(screens.count) (main=\(screens.firstIndex(of: NSScreen.main ?? screens[0]) ?? -1))")
            ForEach(Array(screens.enumerated()), id: \.offset) { idx, sc in
                row("  [\(idx)]", "\(Int(sc.frame.width))×\(Int(sc.frame.height)) @ \(sc.backingScaleFactor)x · origin=(\(Int(sc.frame.minX)),\(Int(sc.frame.minY))) · \(sc.maximumFramesPerSecond)Hz")
            }

            Divider().padding(.vertical, 2)

            // Settings (compact)
            row("Codeword",     "\(settings.codeword.count) chars")
            row("Duration",     "\(settings.durationMinutes) min")
            row("Sound",        settings.soundEnabled ? "on · vol \(Int(settings.soundVolume * 100))% · \(settings.soundFileDisplayName ?? "synth")" : "off")
            row("Effect",       settings.effectEnabled ? "\(settings.screenEffect.label) · \(settings.sparkCount)/burst" : "off")
            row("Pixel grid",   "\(settings.cellsPerAxis) cells/X · \(settings.backgroundColor.label) → \(settings.pixelColor.label)")

            Divider().padding(.vertical, 2)

            // Lock state (live)
            row("Lock",         controller.isLocked ? "active\(controller.isPaused ? " (paused)" : "") · \(controller.remainingSeconds)s left" : "idle")
            row("Windows",      "\(controller.lockWindowCount) · screenSaver+stationary")
            row("Event tap",    controller.eventTapInstalled ? "active" : "inactive")
            row("Space obs.",   controller.spaceObserverInstalled ? "active" : "inactive")
            row("Audio",        controller.soundDiagnostic)
            row("Accessibility", AccessibilityPermission.isGranted ? "granted ✓" : "denied ✗")

            Divider().padding(.vertical, 2)

            // Counters
            row("Keyboard",     "L=\(controller.letterCount) N=\(controller.numberCount) Fn=\(controller.fnKeyCount) Sys=\(controller.systemKeyCount) Oth=\(controller.otherKeyCount)")
            row("Mouse",        "L=\(controller.leftClickCount) R=\(controller.rightClickCount) M=\(controller.middleClickCount) back=\(controller.backClickCount) fwd=\(controller.forwardClickCount)")
            row("Scroll/Gest",  "scroll=\(controller.scrollCount) · spaces=\(controller.spaceSwitchCount)")
            row("Heatmap",      "\(controller.keyCounts.count) keys / \(controller.keyCounts.values.reduce(0, +)) presses")
        }
        .font(.system(.caption, design: .monospaced))
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        )
        .onReceive(timer) { _ in
            screens = NSScreen.screens
            tick &+= 1
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func appVersion() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    private func machineArch() -> String {
        var sys = utsname()
        uname(&sys)
        return withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingUTF8: $0) ?? "?" }
        }
    }
}
