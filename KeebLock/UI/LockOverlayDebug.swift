import SwiftUI

/// Border-strip live-debug HUD that wraps around the inside edge of the
/// lock window. Off by default; the user opts in via Settings → Debug →
/// "Lock-screen overlay" picker. Each tier adds another strip:
///
///   .minimal  — top strip only: live counters (keys / mouse / gestures)
///   .standard — + bottom strip: PerfMetrics summary
///   .verbose  — + right strip: top heat keys + active subsystem flags
///
/// All strips are non-interactive (`.allowsHitTesting(false)`) so they
/// can't swallow clicks meant for the unlock button or the codeword
/// field. Spark / effect intensity in the lock window scales down via
/// `AppSettings.effectiveSparkCount` while the overlay is on.
// Layout constants are inline below with self-evident SwiftUI modifier
// names (`.padding`, `.spacing`, `.font(size:)`). The numbers themselves
// are tuned by eye for a 13" screen — large enough to read at a glance,
// small enough to leave the lock card breathing room. Group fonts in
// the 8/11 pt monospaced range, padding 6-14 pt, opacities 0.35 (dim) /
// 0.6 (label) / 0.78 (strip bg).
struct LockOverlayDebug: View {
    var controller: LockController
    let level: LockOverlayDebugLevel

    @ObservedObject private var perf: PerfMetrics = .shared
    @State private var snapshotToast: String?

    var body: some View {
        // Subscribe to displayTick so the 1 Hz pulse drives strip refreshes;
        // counters live as @ObservationIgnored to keep them off the per-event
        // observation cascade.
        let _ = controller.displayTick
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                topStrip
                Spacer(minLength: 0)
                if level >= .standard {
                    bottomStrip
                }
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if level >= .verbose {
                    rightStrip
                }
            }
            // Snapshot button — drawn here purely for visual feedback;
            // the click is intercepted at the event-tap level by
            // LockController.isInsideInlineSnapshotRegion, so this view
            // doesn't need (and can't reliably get) hit-testing while
            // the lock blocks mouse-down at the OS level.
            snapshotButton
                .padding(.top, LockController.inlineSnapshotButtonMargin)
                .padding(.trailing, LockController.inlineSnapshotButtonMargin)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .onChange(of: controller.snapshotPulse) { _, _ in
            snapshotToast = "SAVED  ✓"
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(1500))
                snapshotToast = nil
            }
        }
    }

    private var snapshotButton: some View {
        let saved = snapshotToast != nil
        return HStack(spacing: 6) {
            Image(systemName: saved ? "checkmark.circle.fill" : "camera.aperture")
            Text(snapshotToast ?? "SNAPSHOT")
                .tracking(0.8)
        }
        .font(.system(size: 11, weight: .heavy, design: .monospaced))
        .foregroundStyle(.black)
        .frame(
            width: LockController.inlineSnapshotButtonWidth,
            height: LockController.inlineSnapshotButtonHeight
        )
        .background(
            Capsule()
                .fill(saved ? Color.green.opacity(0.92) : Color.orange.opacity(0.88))
        )
        .overlay(
            Capsule()
                .strokeBorder(.black.opacity(0.5), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
    }

    // MARK: - Top: input counters

    private var topStrip: some View {
        HStack(spacing: 18) {
            field("WIPES",    "\(controller.keystrokeCount)")
            field("LET",      "\(controller.letterCount)",     dim: controller.letterCount == 0)
            field("NUM",      "\(controller.numberCount)",     dim: controller.numberCount == 0)
            field("SYM",      "\(controller.symbolCount)",     dim: controller.symbolCount == 0)
            field("CTL",      "\(controller.controlKeyCount)", dim: controller.controlKeyCount == 0)
            field("FN",       "\(controller.functionKeyCount)", dim: controller.functionKeyCount == 0)
            field("MED",      "\(controller.mediaKeyCount)",   dim: controller.mediaKeyCount == 0)
            divider
            field("L",        "\(controller.leftClickCount)",  dim: controller.leftClickCount == 0)
            field("R",        "\(controller.rightClickCount)", dim: controller.rightClickCount == 0)
            field("M",        "\(controller.middleClickCount)", dim: controller.middleClickCount == 0)
            field("BCK",      "\(controller.backClickCount)",  dim: controller.backClickCount == 0)
            field("FWD",      "\(controller.forwardClickCount)", dim: controller.forwardClickCount == 0)
            field("SCRL",     "\(controller.scrollCount)",      dim: controller.scrollCount == 0)
            divider
            field("SWP",      "\(controller.swipeCount)",   dim: controller.swipeCount == 0)
            field("PIN",      "\(controller.pinchCount)",   dim: controller.pinchCount == 0)
            field("ROT",      "\(controller.rotateCount)",  dim: controller.rotateCount == 0)
            divider
            field("MATCH",    "\(controller.codewordMatchProgress)/\(controller.currentCodeword.count)")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(stripBackground)
    }

    // MARK: - Bottom: perf metrics

    private var bottomStrip: some View {
        HStack(spacing: 18) {
            field("CB-AVG",  fmtUs(perf.eventCallbackAvgNs))
            field("CB-MAX",  fmtUs(perf.eventCallbackMaxNs))
            field("CB-P99",  fmtUs(perf.eventCallbackP99Ns))
            field("SAMPLES", "\(perf.eventCallbackSamples)", dim: perf.eventCallbackSamples == 0)
            divider
            field("EVT/s",   "\(perf.eventTapEventsPerSec)")
            field("WIPE/s",  "\(perf.wipeCallsPerSec)")
            field("HOP/s",   "\(perf.mainHopsPerSec)", dim: perf.mainHopsPerSec == 0)
            divider
            field("NSEVT",   "\(perf.nsEventAllocations)", dim: perf.nsEventAllocations == 0)
            field("UDw",     "\(perf.userDefaultsWrites)", dim: perf.userDefaultsWrites == 0)
            field("JSON",    "\(perf.jsonEncodeCount)/\(perf.jsonDecodeCount)")
            divider
            field("MEM",     String(format: "%.0fMB", perf.memoryNowMB))
            field("ΔMEM",    String(format: "%+.1fMB", perf.memoryDeltaMB))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(stripBackground)
    }

    // MARK: - Right: top heat keys + subsystem flags

    private var rightStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TOP KEYS")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            ForEach(topSessionKeys, id: \.0) { code, count in
                HStack {
                    Text(String(format: "0x%02X", code))
                        .frame(width: 36, alignment: .leading)
                    Text("\(count)")
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            Divider().background(.white.opacity(0.2))
            Text("STATE")
                .font(.system(size: 9, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            flag("LOCK", controller.isLocked)
            flag("PAUS", controller.isPaused)
            flag("TAP",  controller.eventTapInstalled)
            flag("OBS",  controller.spaceObserverInstalled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: 130)
        .background(stripBackground)
    }

    private var topSessionKeys: [(UInt16, Int)] {
        controller.sessionKeyCounts
            .sorted { $0.value > $1.value }
            .prefix(8)
            .map { ($0.key, $0.value) }
    }

    // MARK: - Helpers

    private func field(_ label: String, _ value: String, dim: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(dim ? 0.35 : 0.6))
                .tracking(0.6)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(dim ? 0.35 : 1.0))
        }
    }

    private func flag(_ label: String, _ on: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(on ? Color.green : Color.red.opacity(0.5))
                .frame(width: 6, height: 6)
            Text(label)
                .foregroundStyle(.white.opacity(on ? 1.0 : 0.45))
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.15))
            .frame(width: 1, height: 22)
    }

    private var stripBackground: some View {
        Color.black.opacity(0.78)
    }

    private func fmtUs(_ ns: UInt64) -> String {
        let us = Double(ns) / 1000
        if us >= 1000 { return String(format: "%.1fms", us / 1000) }
        if us >= 10   { return String(format: "%.0fµs", us) }
        return String(format: "%.1fµs", us)
    }
}
