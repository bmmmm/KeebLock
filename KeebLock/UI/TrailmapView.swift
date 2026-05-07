import SwiftUI

// Polyline visualisation of how the user moved across the keyboard
// during cleaning sessions. Each `TrailPoint` is placed at the
// normalised on-screen position of its keycode (via
// `KeyboardPositionMap`); successive points are connected by a line
// whose colour reflects the chosen scheme. The view never updates
// during a lock — Settings is unreachable while locked — so the trail
// is effectively a static snapshot when rendered.
struct TrailmapView: View {
    var controller: LockController
    @ObservedObject private var settings: AppSettings = .shared
    @Environment(\.dismiss) private var dismiss

    enum Scope: String, CaseIterable, Identifiable {
        case session = "Current session"
        case overall = "Overall"
        var id: String { rawValue }
    }

    enum ColorMode: String, CaseIterable, Identifiable {
        case hueGradient = "Hue gradient"
        case themeAccent = "Theme accent"
        case monochrome  = "Monochrome"
        var id: String { rawValue }
    }

    @State private var scope: Scope = .session
    @State private var colorMode: ColorMode = .hueGradient
    @State private var blurRadius: Double = 6
    @State private var lineWidth: Double = 2

    private var trail: [TrailPoint] {
        switch scope {
        case .session: return controller.sessionTrail
        case .overall: return controller.overallTrail
        }
    }

    /// Trail filtered to keycodes the layout knows about, paired with
    /// their normalised position. Computed once per render so the two
    /// Canvas passes (glow + sharp) share one walk.
    private var plottable: [(timestamp: TimeInterval, normPos: CGPoint)] {
        trail.compactMap { p in
            guard let pos = KeyboardPositionMap.normalizedPosition(for: p.keycode) else {
                return nil
            }
            return (p.timestamp, pos)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    controls
                    canvas
                    if plottable.isEmpty {
                        empty
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 620)
    }

    // MARK: - Header / Footer

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Trailmap")
                    .font(.title2).fontWeight(.semibold)
                Text(headerSubtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $scope) {
                ForEach(Scope.allCases) { s in
                    Text(s.rawValue).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var headerSubtitle: String {
        let plotted = plottable.count
        let total = trail.count
        let dropped = total - plotted
        let droppedNote = dropped > 0 ? " · \(dropped) skipped (no key map)" : ""
        return "\(plotted) wipes · \(durationLabel)\(droppedNote)"
    }

    private var durationLabel: String {
        guard let first = trail.first?.timestamp,
              let last  = trail.last?.timestamp,
              last > first else {
            return "—"
        }
        return formatDuration(Int(last - first))
    }

    private func formatDuration(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        if m < 60 { return r == 0 ? "\(m) min" : "\(m) min \(r)s" }
        let h = m / 60
        let rm = m % 60
        return rm == 0 ? "\(h) h" : "\(h) h \(rm) min"
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                switch scope {
                case .session: controller.resetSessionTrailmap()
                case .overall: controller.resetOverallTrailmap()
                }
            } label: {
                Label("Reset \(scope.rawValue.lowercased()) trailmap",
                      systemImage: "arrow.counterclockwise")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(plottable.isEmpty)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Color", selection: $colorMode) {
                ForEach(ColorMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 12) {
                Image(systemName: "drop")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(value: $blurRadius, in: 0...20)
                Text("Glow \(Int(blurRadius))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }

            HStack(spacing: 12) {
                Image(systemName: "line.diagonal")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Slider(value: $lineWidth, in: 0.5...8)
                Text("Width \(String(format: "%.1f", lineWidth))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .trailing)
            }
        }
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.88))

            // Two Canvas passes with the same content: the lower one
            // is blurred for a halo/glow, the upper stays sharp so
            // the line cores remain crisp regardless of blur radius.
            Canvas { ctx, size in
                drawTrail(ctx: ctx, size: size)
            }
            .blur(radius: blurRadius)

            Canvas { ctx, size in
                drawTrail(ctx: ctx, size: size)
            }
        }
        .frame(height: 360)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func drawTrail(ctx: GraphicsContext, size: CGSize) {
        let points = plottable
        guard points.count > 1 else { return }
        let denominator = Double(max(1, points.count - 1))
        var previous: CGPoint?
        for (idx, entry) in points.enumerated() {
            let screen = CGPoint(
                x: entry.normPos.x * size.width,
                y: entry.normPos.y * size.height
            )
            if let prev = previous {
                var path = Path()
                path.move(to: prev)
                path.addLine(to: screen)
                let progress = Double(idx) / denominator
                ctx.stroke(path,
                           with: .color(lineColor(progress: progress)),
                           lineWidth: lineWidth)
            }
            previous = screen
        }
    }

    private func lineColor(progress: Double) -> Color {
        switch colorMode {
        case .hueGradient:
            // Old → blue, new → red. 0.65 hue (blue) lerps down to 0
            // (red). Full saturation/brightness for a vivid neon trail.
            let hue = max(0, 0.65 - progress * 0.65)
            return Color(hue: hue, saturation: 0.85, brightness: 0.98)
        case .themeAccent:
            return settings.appTheme.color.opacity(0.30 + progress * 0.70)
        case .monochrome:
            return Color.white.opacity(0.25 + progress * 0.75)
        }
    }

    // MARK: - Empty

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "scribble.variable")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No trail recorded yet — start a lock and wipe a few keys.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}
