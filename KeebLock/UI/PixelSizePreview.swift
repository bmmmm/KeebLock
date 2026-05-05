import SwiftUI

// Small live preview rendering a grid of color blocks at the configured size.
// Shows the user what `pixelFineness` actually looks like before locking.
struct PixelSizePreview: View {
    let cellsX: Int
    let color: Color
    var cornerRadius: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let cellSize = w / Double(max(1, cellsX))
            let cellsY  = max(1, Int(h / cellSize))

            Canvas { ctx, _ in
                for x in 0..<cellsX {
                    for y in 0..<cellsY {
                        let rect = CGRect(
                            x: Double(x) * cellSize,
                            y: Double(y) * cellSize,
                            width: cellSize,
                            height: cellSize
                        )
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
}
