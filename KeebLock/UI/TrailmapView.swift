import Carbon
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
    @ObservedObject private var inputSource = InputSourceObserver.shared
    @Environment(\.dismiss) private var dismiss

    enum ColorMode: String, CaseIterable, Identifiable {
        case hueGradient = "Hue gradient"
        case themeAccent = "Theme accent"
        case monochrome  = "Monochrome"
        var id: String { rawValue }
    }

    /// Canvas backdrop. `keyboard` draws the layout behind the trail so a
    /// stroke can be read against the key it landed on; `plain` is the bare
    /// dark canvas. Keyboard is the default — without it the trail is a set
    /// of lines floating in space with no spatial reference.
    enum Backdrop: String, CaseIterable, Identifiable {
        case keyboard = "Keyboard"
        case plain    = "Plain"
        var id: String { rawValue }
    }

    @State private var backdrop: Backdrop = .keyboard
    @State private var colorMode: ColorMode = .hueGradient
    @State private var blurRadius: Double = 6
    @State private var lineWidth: Double = 2

    /// Layout-translated key labels for the keyboard backdrop, so it reads in
    /// the user's actual layout (Y↔Z and umlauts on QWERTZ, etc.) — same as
    /// the Cleanmap. Rebuilt on appear and when the active input source
    /// changes. Empty until built; `resolvedLabel` falls back to the static
    /// US label meanwhile.
    @State private var dynamicLabels: [UInt16: String] = [:]

    /// Modifier / special keycodes whose labels stay as their hard-coded
    /// glyphs — UCKeyTranslate would return control chars or the same letter
    /// on every layout for these, so static is more useful.
    private static let staticLabelKeycodes: Set<UInt16> = [
        53,                                                        // esc
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,    // F1–F12
        51, 48, 57, 36,                                            // delete tab caps return
        56, 60,                                                    // shift
        63, 59, 62, 58, 61, 55, 54, 49,                            // fn ctrl opt cmd space
        123, 124, 125, 126,                                        // arrows
    ]

    private var trail: [TrailPoint] { controller.sessionTrail }

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
        // No displayTick subscription: TrailmapView is only reachable from
        // Settings (hidden behind the lock), so per-frame trail growth
        // during a lock is invisible to the user anyway. The view
        // re-evaluates when it is presented (on user navigation) and
        // reads the current sessionTrail value at that point.
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
        .onAppear { rebuildDynamicLabels() }
        .onChange(of: inputSource.sourceID) { _, _ in rebuildDynamicLabels() }
    }

    /// Per-key label: layout-translated when available, otherwise the
    /// hard-coded fallback (modifier glyphs, F-keys, special keys).
    private func resolvedLabel(for key: KeyboardKey) -> String {
        if let code = key.code, let dyn = dynamicLabels[code] { return dyn }
        return key.label
    }

    /// Walk the layout's keycodes once, ask UCKeyTranslate for the
    /// layout-correct label, cache. Cheap and only fires on view show /
    /// layout switch — never per-frame.
    private func rebuildDynamicLabels() {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return }
        var map: [UInt16: String] = [:]
        for row in KeyboardLayout.rows {
            for key in row {
                guard let code = key.code,
                      !Self.staticLabelKeycodes.contains(code) else { continue }
                if let label = KeyboardLayoutLookup.translate(keycode: code, source: src) {
                    map[code] = label
                }
            }
        }
        dynamicLabels = map
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
                controller.resetSessionTrailmap()
            } label: {
                Label("Reset trailmap", systemImage: "arrow.counterclockwise")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(plottable.isEmpty)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("w", modifiers: .command)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Backdrop", selection: $backdrop) {
                ForEach(Backdrop.allCases) { bg in
                    Text(bg.rawValue).tag(bg)
                }
            }
            .pickerStyle(.segmented)

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
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(Color.black.opacity(0.88))

            // Keyboard backdrop, drawn with the SAME per-row normalisation
            // KeyboardPositionMap uses to place trail points, so a stroke
            // lands exactly on the key it was made on.
            if backdrop == .keyboard {
                Canvas { ctx, size in
                    drawKeyboard(ctx: ctx, size: size)
                }
            }

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
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    /// Renders the keyboard layout as a faint backdrop. Each row is stretched
    /// to fill the full width and normalised by its own unit total — identical
    /// to `KeyboardPositionMap`'s coordinate maths — so the trail (which reads
    /// from that map) aligns key-for-key on top of it.
    private func drawKeyboard(ctx: GraphicsContext, size: CGSize) {
        let rowCount = KeyboardLayout.rows.count
        guard rowCount > 0 else { return }
        let rowHeight = size.height / CGFloat(rowCount)
        let gap: CGFloat = 2

        for (rowIdx, row) in KeyboardLayout.rows.enumerated() {
            let totalWidth = row.reduce(CGFloat(0)) { $0 + $1.width }
            guard totalWidth > 0 else { continue }
            let yMin = CGFloat(rowIdx) * rowHeight
            var cursor: CGFloat = 0

            for key in row {
                let xMin = cursor / totalWidth * size.width
                cursor += key.width
                let xMax = cursor / totalWidth * size.width

                let rect = CGRect(x: xMin + gap, y: yMin + gap,
                                  width: (xMax - xMin) - gap * 2,
                                  height: rowHeight - gap * 2)
                guard rect.width > 0, rect.height > 0 else { continue }

                let shape = Path(roundedRect: rect, cornerRadius: 3)
                ctx.fill(shape, with: .color(.white.opacity(0.045)))
                ctx.stroke(shape, with: .color(.white.opacity(0.12)), lineWidth: 1)

                guard key.code != nil else { continue }
                let fontSize = min(10, rect.height * 0.4)
                var label = ctx.resolve(
                    Text(resolvedLabel(for: key)).font(.system(size: fontSize, weight: .medium))
                )
                label.shading = .color(.white.opacity(0.22))
                ctx.draw(label, at: CGPoint(x: rect.midX, y: rect.midY))
            }
        }
    }

    private func drawTrail(ctx: GraphicsContext, size: CGSize) {
        let points = plottable
        guard points.count > 1 else { return }
        let denominator = Double(max(1, points.count - 1))
        let segmentCount = points.count - 1
        // Cap arrows at ~30 across the whole trail so the screen never
        // gets crowded; minimum every 5th segment so short trails still
        // get a couple of direction hints.
        let arrowEvery = max(5, segmentCount / 30)
        let arrowSize = max(4.0, lineWidth * 2.5)

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
                let color = lineColor(progress: progress)
                ctx.stroke(path, with: .color(color), lineWidth: lineWidth)

                let segIdx = idx - 1
                if segIdx % arrowEvery == 0 {
                    drawArrow(ctx: ctx, from: prev, to: screen,
                              size: arrowSize, color: color)
                }
            }
            previous = screen
        }
    }

    /// Draws a small V-shaped chevron at the segment's end, pointing in
    /// the direction of travel. Skipped for segments shorter than the
    /// arrow itself so it never folds back on a stay-in-place wipe
    /// (same key pressed twice → zero-length segment).
    private func drawArrow(ctx: GraphicsContext,
                           from start: CGPoint,
                           to end: CGPoint,
                           size: Double,
                           color: Color) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > size else { return }
        let nx = dx / length
        let ny = dy / length
        let px = -ny
        let py = nx
        let baseX = end.x - nx * size
        let baseY = end.y - ny * size
        let wing = size * 0.6
        let left  = CGPoint(x: baseX + px * wing, y: baseY + py * wing)
        let right = CGPoint(x: baseX - px * wing, y: baseY - py * wing)
        var path = Path()
        path.move(to: left)
        path.addLine(to: end)
        path.addLine(to: right)
        ctx.stroke(path, with: .color(color), lineWidth: lineWidth)
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
