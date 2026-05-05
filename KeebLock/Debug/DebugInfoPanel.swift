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

            row("macOS",        ProcessInfo.processInfo.operatingSystemVersionString)
            row("Arch",         machineArch())
            row("App version",  appVersion())
            row("Bundle ID",    Bundle.main.bundleIdentifier ?? "?")

            Divider().padding(.vertical, 2)

            row("Screens",      "\(screens.count)")
            ForEach(Array(screens.enumerated()), id: \.offset) { idx, sc in
                row("  [\(idx)]", "\(Int(sc.frame.width))×\(Int(sc.frame.height)) @ \(sc.backingScaleFactor)x  origin=(\(Int(sc.frame.minX)), \(Int(sc.frame.minY)))")
            }

            Divider().padding(.vertical, 2)

            row("Pixel grid",   "\(settings.cellsPerAxis) cells/X (\(settings.pixelFineness)/10)")
            row("Background",   settings.backgroundColor.label)
            row("Pixel color",  settings.pixelColor.label)
            row("Effect",       settings.effectEnabled ? "\(settings.screenEffect.label) · \(settings.sparkCount)/burst" : "off")
            row("Sound",        settings.soundEnabled ? "vol \(Int(settings.soundVolume * 100))%" : "off")
            row("Sound source", settings.soundFileDisplayName ?? "synth click (default)")
            row("Codeword",     "\(settings.codeword.count) chars")
            row("Duration",     "\(settings.durationMinutes) min")

            Divider().padding(.vertical, 2)

            row("Accessibility", AccessibilityPermission.isGranted ? "granted ✓" : "denied ✗")
            row("Lock state",    controller.isLocked ? "active · \(controller.keystrokeCount) keys · \(controller.remainingSeconds)s left" : "idle")
            row("Heatmap data",  "\(controller.keyCounts.count) keys, \(controller.keyCounts.values.reduce(0, +)) presses total")

            Divider().padding(.vertical, 2)

            row("Left clicks",   "\(controller.leftClickCount)")
            row("Right clicks",  "\(controller.rightClickCount)")
            row("Fn key hits",   "\(controller.fnKeyCount)")
            row("Miss clicks",   "\(controller.missClickCount) total")
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
