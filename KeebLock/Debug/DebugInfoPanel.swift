import AppKit
import Combine
import SwiftUI

// Live debug overlay shown in the Settings tab when AppSettings.debugLoggingEnabled
// is true. Refreshes on the controller's throttled displayTick (10-30 Hz
// CADisplayLink) plus PerfMetrics' 1 Hz tickSeq, so screens, lock state and
// counts stay current.
struct DebugInfoPanel: View {
    @ObservedObject var settings: AppSettings
    var controller: LockController
    @ObservedObject private var perf: PerfMetrics = .shared

    @State private var screens: [NSScreen] = NSScreen.screens

    var body: some View {
        // Subscribe to the throttled displayTick so the counter rows
        // refresh even though the per-event mutations don't fire
        // observation tracking themselves.
        let _ = controller.displayTick
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "ladybug.fill")
                Text("Live debug").font(.caption.weight(.semibold))
                Spacer()
            }
            .foregroundStyle(.orange)

            // App + system
            row("App",          appVersion())
            row("macOS",        ProcessInfo.processInfo.operatingSystemVersionString + " · " + DebugLog.machineArch())
            row("Frontmost",    NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")

            Divider().padding(.vertical, 2)

            // Screens
            row("Screens",      "\(screens.count) (main=\((NSScreen.main ?? screens.first).flatMap { screens.firstIndex(of: $0) } ?? -1))")
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
            row("Keyboard",     "Let=\(controller.letterCount) Num=\(controller.numberCount) Sym=\(controller.symbolCount) Ctl=\(controller.controlKeyCount) Fn=\(controller.functionKeyCount) Med=\(controller.mediaKeyCount)")
            row("Mouse",        "L=\(controller.leftClickCount) R=\(controller.rightClickCount) M=\(controller.middleClickCount) back=\(controller.backClickCount) fwd=\(controller.forwardClickCount)")
            row("Scroll",       "scroll=\(controller.scrollCount)")
            row("Gestures",     "swipes=\(controller.swipeCount) · pinch=\(controller.pinchCount) · rotate=\(controller.rotateCount)")
            row("Cleanmap S",   "\(controller.sessionKeyCounts.count) keys / \(controller.sessionKeyCounts.values.reduce(0, +)) wipes")
            row("Cleanmap O",   "\(controller.overallKeyCounts.count) keys / \(controller.overallKeyCounts.values.reduce(0, +)) wipes (persisted)")

            Divider().padding(.vertical, 2)

            // Performance
            row("Cb latency",   latencyLine)
            row("Rates /s",     "events=\(perf.eventTapEventsPerSec) wipes=\(perf.wipeCallsPerSec) mainHops=\(perf.mainHopsPerSec)")
            row("Allocations",  "NSEvent=\(perf.nsEventAllocations) JSONenc=\(perf.jsonEncodeCount) JSONdec=\(perf.jsonDecodeCount) UDw=\(perf.userDefaultsWrites)")
            row("Memory",       memoryLine)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(12)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(.orange.opacity(0.3), lineWidth: 1)
        )
        // NSScreen list mutates via this notification (display added/removed,
        // resolution change, mirror toggle). PerfMetrics @Published republish
        // already drives the per-second figures; no separate timer needed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
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

    private var latencyLine: String {
        if perf.eventCallbackSamples == 0 {
            // Latency sampling is always on (only the per-event string ring
            // is gated on verbose perf) — zero samples just means no lock
            // session has run yet.
            return "—  (no events sampled yet — start a lock)"
        }
        let avg = Double(perf.eventCallbackAvgNs) / 1000
        let max = Double(perf.eventCallbackMaxNs) / 1000
        let p99 = Double(perf.eventCallbackP99Ns) / 1000
        return String(format: "avg %.1fµs · max %.1fµs · p99 %.1fµs · n=%d",
                      avg, max, p99, perf.eventCallbackSamples)
    }

    private var memoryLine: String {
        String(format: "%.1fMB now · Δ %+.1fMB since lock-start",
               perf.memoryNowMB, perf.memoryDeltaMB)
    }

    private func appVersion() -> String { Bundle.main.keeblockVersionString }
}
