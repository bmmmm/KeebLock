import SwiftUI

// MARK: - Particle types

private struct SparkParticle: Identifiable {
    let id = UUID()
    let x, y, size: Double
    let color: Color
    let born: Date = .now
    static let lifetime = 0.85
}

private struct RainDrop: Identifiable {
    let id = UUID()
    let x, y, length, speed: Double
    let born: Date = .now
    static let lifetime = 0.75
}

private struct MatrixChar: Identifiable {
    let id = UUID()
    let x, y, speed: Double
    let char: String
    let born: Date = .now
    static let lifetime = 1.1
}

private struct BubbleParticle: Identifiable {
    let id = UUID()
    let x, y, size, speed: Double
    let born: Date = .now
    static let lifetime = 1.4
}

private struct SnowFlake: Identifiable {
    let id = UUID()
    let x, y, size, speed, drift, phase: Double
    let born: Date = .now
    static let lifetime = 2.0
}

// MARK: - Size preference key

private struct SparkViewSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

// MARK: - Effect overlay (all 5 effects in one view)

struct SparkOverlayView: View {
    let triggerCount: Int

    @State private var sparks:   [SparkParticle]  = []
    @State private var drops:    [RainDrop]         = []
    @State private var chars:    [MatrixChar]       = []
    @State private var bubbles:  [BubbleParticle]   = []
    @State private var flakes:   [SnowFlake]        = []
    @State private var viewSize: CGSize = .zero
    @State private var spawnPending: Bool = false

    private static let sparkColors: [Color] = [
        Color(red: 1.0, green: 0.72, blue: 0.82),
        Color(red: 0.80, green: 0.69, blue: 0.98),
        Color(red: 0.68, green: 0.98, blue: 0.82),
        Color(red: 1.0, green: 0.95, blue: 0.55),
        Color(red: 0.68, green: 0.90, blue: 1.0),
        Color(red: 1.0, green: 0.84, blue: 0.60),
    ]
    private static let matrixAlphabet = Array("アイウエカキクケサシスセタチツテ0123456789ABCDEF")

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, size in
                let now = tl.date
                switch AppSettings.shared.screenEffect {
                case .sparks:  drawSparks(ctx: ctx, now: now)
                case .rain:    drawRain(ctx: ctx, now: now, size: size)
                case .matrix:  drawMatrix(ctx: ctx, now: now, size: size)
                case .bubbles: drawBubbles(ctx: ctx, now: now, size: size)
                case .snow:    drawSnow(ctx: ctx, now: now, size: size)
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: SparkViewSizeKey.self, value: geo.size)
            }
        )
        .onPreferenceChange(SparkViewSizeKey.self) { viewSize = $0 }
        .onChange(of: triggerCount) { _, _ in
            guard AppSettings.shared.effectEnabled else { return }
            // Coalesce: if a spawn is already scheduled for this frame, skip.
            // Rapid trigger bursts (typing, scroll wheel) would otherwise
            // schedule several async blocks that all mutate State within the
            // same runloop tick — SwiftUI flags that as "onChange tried to
            // update multiple times per frame". One spawn per frame is plenty
            // for the visual effect.
            guard !spawnPending else { return }
            spawnPending = true
            let size = viewSize.width > 0 ? viewSize : CGSize(width: 1920, height: 1080)
            DispatchQueue.main.async {
                spawnPending = false
                spawn(in: size)
            }
        }
    }

    // MARK: - Spawn dispatcher

    private func spawn(in size: CGSize) {
        let count = AppSettings.shared.effectiveSparkCount
        guard count > 0 else { return }
        switch AppSettings.shared.screenEffect {
        case .sparks:  spawnSparks(in: size, count: count)
        case .rain:    spawnRain(in: size, count: count)
        case .matrix:  spawnMatrix(in: size, count: count)
        case .bubbles: spawnBubbles(in: size, count: count)
        case .snow:    spawnSnow(in: size, count: count)
        }
    }

    // MARK: - Sparks

    private func spawnSparks(in size: CGSize, count: Int) {
        // Filter dead particles BEFORE adding new ones — was the main source
        // of lag near codeword completion. Without this, the canvas iterated
        // hundreds of expired particles on every frame just to `continue` past
        // them in drawSparks. count*25 hard-cap (=750 for default count=30)
        // also amplified the cost.
        let now = Date()
        sparks.removeAll { now.timeIntervalSince($0.born) >= SparkParticle.lifetime }

        let m = 80.0
        let cx = Double.random(in: m...max(m+1, size.width - m))
        let cy = Double.random(in: m...max(m+1, size.height - m))
        for _ in 0..<count {
            let a = Double.random(in: 0..<(.pi * 2))
            let d = Double.random(in: 15...70)
            sparks.append(SparkParticle(
                x: cx + cos(a) * d, y: cy + sin(a) * d,
                size: Double.random(in: 5...13),
                color: Self.sparkColors.randomElement()!
            ))
        }
        // Generous safety cap kept for runaway-spawn protection only.
        if sparks.count > 200 { sparks.removeFirst(sparks.count - 200) }
    }

    private func drawSparks(ctx: GraphicsContext, now: Date) {
        for p in sparks {
            let age = now.timeIntervalSince(p.born)
            guard age < SparkParticle.lifetime else { continue }
            let t = age / SparkParticle.lifetime
            var g = ctx
            g.opacity = pow(1.0 - t, 1.5)
            g.translateBy(x: p.x, y: p.y - t * 60)
            g.scaleBy(x: 0.5 + t * 0.6, y: 0.5 + t * 0.6)
            let r = p.size / 2
            g.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: p.size, height: p.size)),
                   with: .color(p.color))
        }
    }

    // MARK: - Rain

    private func spawnRain(in size: CGSize, count: Int) {
        let now = Date()
        drops.removeAll { now.timeIntervalSince($0.born) >= RainDrop.lifetime }
        let n = max(2, count / 2)
        for _ in 0..<n {
            drops.append(RainDrop(
                x: Double.random(in: 0...size.width),
                y: Double.random(in: -20...size.height * 0.2),
                length: Double.random(in: 22...55),
                speed: Double.random(in: 200...420)
            ))
        }
        if drops.count > 200 { drops.removeFirst(drops.count - 200) }
    }

    private func drawRain(ctx: GraphicsContext, now: Date, size: CGSize) {
        for d in drops {
            let age = now.timeIntervalSince(d.born)
            guard age < RainDrop.lifetime else { continue }
            let t = age / RainDrop.lifetime
            let y0 = d.y + d.speed * age
            guard y0 < size.height + d.length else { continue }
            var path = Path()
            path.move(to: CGPoint(x: d.x, y: y0))
            path.addLine(to: CGPoint(x: d.x + 0.8, y: y0 + d.length))
            ctx.stroke(path, with: .color(Color(red: 0.45, green: 0.78, blue: 1.0).opacity((1 - t) * 0.65)),
                       lineWidth: 1.5)
        }
    }

    // MARK: - Matrix

    private func spawnMatrix(in size: CGSize, count: Int) {
        let now = Date()
        chars.removeAll { now.timeIntervalSince($0.born) >= MatrixChar.lifetime }
        let n = max(1, count / 3)
        for _ in 0..<n {
            chars.append(MatrixChar(
                x: Double.random(in: 10...size.width - 10),
                y: Double.random(in: -10...size.height * 0.3),
                speed: Double.random(in: 100...260),
                char: String(Self.matrixAlphabet.randomElement()!)
            ))
        }
        if chars.count > 200 { chars.removeFirst(chars.count - 200) }
    }

    private func drawMatrix(ctx: GraphicsContext, now: Date, size: CGSize) {
        for mc in chars {
            let age = now.timeIntervalSince(mc.born)
            guard age < MatrixChar.lifetime else { continue }
            let t = age / MatrixChar.lifetime
            let y = mc.y + mc.speed * age
            guard y < size.height + 20 else { continue }
            ctx.draw(
                Text(mc.char)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.0, green: 0.95, blue: 0.3).opacity(pow(1 - t, 1.2) * 0.9)),
                at: CGPoint(x: mc.x, y: y)
            )
        }
    }

    // MARK: - Bubbles

    private func spawnBubbles(in size: CGSize, count: Int) {
        let now = Date()
        bubbles.removeAll { now.timeIntervalSince($0.born) >= BubbleParticle.lifetime }
        let n = max(1, count / 3)
        for _ in 0..<n {
            bubbles.append(BubbleParticle(
                x: Double.random(in: 40...size.width - 40),
                y: Double.random(in: size.height * 0.5...size.height),
                size: Double.random(in: 10...38),
                speed: Double.random(in: 55...130)
            ))
        }
        if bubbles.count > 200 { bubbles.removeFirst(bubbles.count - 200) }
    }

    private func drawBubbles(ctx: GraphicsContext, now: Date, size: CGSize) {
        for b in bubbles {
            let age = now.timeIntervalSince(b.born)
            guard age < BubbleParticle.lifetime else { continue }
            let t = age / BubbleParticle.lifetime
            let opacity = (1.0 - pow(t, 2.0)) * 0.75
            let s = b.size * (1.0 + t * 0.35)
            let cy = b.y - b.speed * age
            guard cy > -s else { continue }
            let r = s / 2
            ctx.stroke(Path(ellipseIn: CGRect(x: b.x - r, y: cy - r, width: s, height: s)),
                       with: .color(Color(red: 0.5, green: 0.88, blue: 1.0).opacity(opacity)),
                       lineWidth: 1.5)
            let hr = s * 0.2
            ctx.fill(
                Path(ellipseIn: CGRect(x: b.x - r * 0.45 - hr / 2, y: cy - r * 0.55, width: hr, height: hr * 0.65)),
                with: .color(Color.white.opacity(opacity * 0.5))
            )
        }
    }

    // MARK: - Snow

    private func spawnSnow(in size: CGSize, count: Int) {
        let now = Date()
        flakes.removeAll { now.timeIntervalSince($0.born) >= SnowFlake.lifetime }
        let n = max(2, count / 2)
        for _ in 0..<n {
            flakes.append(SnowFlake(
                x: Double.random(in: 0...size.width),
                y: Double.random(in: -20...size.height * 0.15),
                size: Double.random(in: 4...14),
                speed: Double.random(in: 45...110),
                drift: Double.random(in: -25...25),
                phase: Double.random(in: 0...(.pi * 2))
            ))
        }
        if flakes.count > 250 { flakes.removeFirst(flakes.count - 250) }
    }

    private func drawSnow(ctx: GraphicsContext, now: Date, size: CGSize) {
        for f in flakes {
            let age = now.timeIntervalSince(f.born)
            guard age < SnowFlake.lifetime else { continue }
            let t = age / SnowFlake.lifetime
            let cx = f.x + f.drift * sin(age * 1.8 + f.phase)
            let cy = f.y + f.speed * age
            guard cy < size.height + f.size else { continue }
            let r = f.size / 2
            ctx.fill(
                Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: f.size, height: f.size)),
                with: .color(Color.white.opacity((1 - pow(t, 1.5)) * 0.9))
            )
        }
    }
}
