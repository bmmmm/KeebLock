import SwiftUI

// Live preview rendering a grid of color blocks at the configured cells-per-axis.
// Mostly background, with a deterministic scatter of "wiped" cells in pixelColor.
// For .random presets, cells are colored with a position-based rainbow;
// bg and pixel rainbows are offset 180° (0.5 hue shift) from each other.
struct PixelSizePreview: View {
    let cellsX: Int
    let backgroundPreset: ColorPreset
    let pixelPreset: ColorPreset
    var aspect: Double = 9.0 / 16.0
    var cornerRadius: CGFloat = 8
    var keysPerSecond: Double = 5.0

    private var cellsY: Int { max(1, Int((Double(cellsX) * aspect).rounded())) }
    private var totalCells: Int { cellsX * cellsY }
    private var etaSeconds: Int { Int((Double(totalCells) / keysPerSecond).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            grid.frame(height: 80)
            caption
        }
    }

    private var grid: some View {
        GeometryReader { geo in
            let w = geo.size.width
            // A transient zero-width layout pass (first pass, offscreen scroll)
            // makes `cell` 0; the row count then divides by it and Int(+inf)/Int(NaN)
            // would trap. Skip drawing until the geometry is real.
            let cell = w > 0 ? w / Double(max(1, cellsX)) : 0
            let visibleRows = cell > 0 ? max(1, Int(geo.size.height / cell)) : 0

            Canvas { ctx, _ in
                for x in 0..<cellsX {
                    for y in 0..<visibleRows {
                        let rect = CGRect(
                            x: Double(x) * cell,
                            y: Double(y) * cell,
                            width: cell,
                            height: cell
                        )
                        let isWiped = (x &* 7 &+ y &* 11) % 9 == 0
                        let preset = isWiped ? pixelPreset : backgroundPreset
                        let hueSeed: Double = isWiped ? 0.5 : 0.0
                        let color = cellColor(preset: preset, x: x, cellsX: cellsX, hueSeed: hueSeed)
                        ctx.fill(Path(rect), with: .color(color))
                        ctx.stroke(
                            Path(rect),
                            with: .color(.black.opacity(0.08)),
                            lineWidth: 0.5
                        )
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.black.opacity(0.15), lineWidth: 1)
        )
    }

    private var caption: some View {
        Text("\(cellsX) × \(cellsY) cells per stage on a 16:9 screen · ~\(formatETA(etaSeconds)) at 5 keys/s")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func cellColor(preset: ColorPreset, x: Int, cellsX: Int, hueSeed: Double) -> Color {
        switch preset {
        case .random:
            let hue = (Double(x) / Double(max(1, cellsX)) + hueSeed).truncatingRemainder(dividingBy: 1.0)
            return Color(hue: hue, saturation: 0.72, brightness: 0.62)
        case .transparent:
            return Color.gray.opacity(0.15)
        default:
            return preset.swiftUIColor
        }
    }

    private func formatETA(_ s: Int) -> String {
        if s < 60 { return "\(s)s" }
        let m = s / 60
        let r = s % 60
        if m < 60 { return r == 0 ? "\(m) min" : "\(m) min \(r)s" }
        let h = m / 60
        let rm = m % 60
        return rm == 0 ? "\(h) h" : "\(h) h \(rm) min"
    }
}
