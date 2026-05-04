import SwiftUI
import AppKit

private struct SparkParticle: Identifiable {
    let id = UUID()
    let x, y: Double
    let color: Color
    let size: Double
    let born: Date = .now
    static let lifetime: Double = 0.85
}

struct SparkOverlayView: View {
    let triggerCount: Int
    let lastMouseScreenPoint: CGPoint
    let screenFrame: CGRect  // AppKit coords (bottom-left origin, global)

    @State private var sparks: [SparkParticle] = []

    private static let sparkColors: [Color] = [
        Color(red: 1.0,  green: 0.72, blue: 0.82),  // rose
        Color(red: 0.80, green: 0.69, blue: 0.98),  // lavender
        Color(red: 0.68, green: 0.98, blue: 0.82),  // mint
        Color(red: 1.0,  green: 0.95, blue: 0.55),  // lemon
        Color(red: 0.68, green: 0.90, blue: 1.0),   // sky
        Color(red: 1.0,  green: 0.84, blue: 0.60),  // peach
    ]

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, _ in
                let now = tl.date
                for spark in sparks {
                    let age = now.timeIntervalSince(spark.born)
                    guard age < SparkParticle.lifetime else { continue }
                    let t = age / SparkParticle.lifetime
                    let opacity = pow(1.0 - t, 1.5)
                    let dy = t * 60.0
                    let scale = 0.5 + t * 0.6

                    var inner = ctx
                    inner.opacity = opacity
                    inner.translateBy(x: spark.x, y: spark.y - dy)
                    inner.scaleBy(x: scale, y: scale)

                    let r = spark.size / 2
                    inner.fill(
                        Path(ellipseIn: CGRect(x: -r, y: -r, width: spark.size, height: spark.size)),
                        with: .color(spark.color)
                    )
                }
            }
        }
        .onChange(of: triggerCount) { _, _ in
            spawnSparks()
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func spawnSparks() {
        // Convert AppKit global coords (bottom-left) to SwiftUI view coords (top-left)
        let lx = lastMouseScreenPoint.x - screenFrame.minX
        let ly = screenFrame.maxY - lastMouseScreenPoint.y

        for _ in 0..<12 {
            let angle = Double.random(in: 0 ..< (.pi * 2))
            let dist  = Double.random(in: 15...70)
            sparks.append(SparkParticle(
                x: lx + cos(angle) * dist,
                y: ly + sin(angle) * dist,
                color: Self.sparkColors.randomElement()!,
                size: Double.random(in: 5...13)
            ))
        }
        // Prevent unbounded growth
        if sparks.count > 300 { sparks.removeFirst(sparks.count - 300) }
    }
}
