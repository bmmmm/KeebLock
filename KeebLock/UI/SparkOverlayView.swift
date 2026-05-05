import SwiftUI

private struct SparkParticle: Identifiable {
    let id = UUID()
    let x, y: Double
    let color: Color
    let size: Double
    let born: Date = .now
    static let lifetime: Double = 0.85
}

// Spawns a small popout of sparks at a random position on this screen each time
// `triggerCount` changes. Mouse position is intentionally ignored — every screen
// reacts to every keystroke independently.
struct SparkOverlayView: View {
    let triggerCount: Int

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
        GeometryReader { geo in
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
                spawnSparks(in: geo.size)
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func spawnSparks(in size: CGSize) {
        let count = AppSettings.shared.sparkCount  // live: slider takes effect immediately
        guard count > 0 else { return }

        let margin: Double = 80
        let cx = Double.random(in: margin...max(margin + 1, size.width - margin))
        let cy = Double.random(in: margin...max(margin + 1, size.height - margin))

        for _ in 0..<count {
            let angle = Double.random(in: 0..<(.pi * 2))
            let dist  = Double.random(in: 15...70)
            sparks.append(SparkParticle(
                x: cx + cos(angle) * dist,
                y: cy + sin(angle) * dist,
                color: Self.sparkColors.randomElement()!,
                size: Double.random(in: 5...13)
            ))
        }
        // Keep the queue bounded — discard oldest when we exceed budget
        let budget = max(300, count * 25)
        if sparks.count > budget { sparks.removeFirst(sparks.count - budget) }
    }
}
