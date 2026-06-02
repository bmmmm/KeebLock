import SwiftUI

// MARK: - Water shape

private struct WaterShape: Shape {
    var fillFraction: Double
    let phase: Double

    var animatableData: Double {
        get { fillFraction }
        set { fillFraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        guard fillFraction > 0 else { return Path() }
        var path = Path()
        let clampedFraction = min(fillFraction, 1.0)
        let waterY = rect.height * (1.0 - clampedFraction)
        // Amplitude fades out as water nears the top
        let amplitude: CGFloat = 5.5 * max(0, 1.0 - (clampedFraction - 0.85) / 0.15)

        path.move(to: CGPoint(x: 0, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: waterY))

        let steps = 80
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = rect.width * t
            let y = waterY + amplitude * sin(t * .pi * 3.5 + phase)
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.closeSubpath()
        return path
    }
}

// MARK: - Water fill button

struct WaterFillButton: View {
    let action: () -> Void
    var disabled: Bool = false
    /// Accent the water gradient + border derive from — pass the active theme
    /// color so the Start CTA follows the theme instead of hardcoding blue
    /// (which clashed with Coffee / Sakura / Sleepy).
    var accent: Color = .accentColor

    @State private var filling = false
    @State private var fillFraction: Double = 0

    private var waterTop: Color    { accent.mix(with: .white, by: 0.35) }
    private var waterBottom: Color { accent.mix(with: .black, by: 0.28) }
    private var borderColor: Color { accent }

    var body: some View {
        // Only mount TimelineView while the wave is actually animating —
        // when the button is idle (fillFraction == 0, not currently filling)
        // the wave path is empty anyway, so a fixed phase produces the same
        // visual at zero per-frame cost. The launcher button used to tick
        // 60–120×/sec just to animate a meniscus that never rendered.
        if filling || fillFraction > 0 {
            TimelineView(.animation) { tl in
                buttonContent(phase: tl.date.timeIntervalSinceReferenceDate * 2.6)
            }
        } else {
            buttonContent(phase: 0)
        }
    }

    private func buttonContent(phase: Double) -> some View {
        Button {
            guard !filling, !disabled else { return }
            filling = true
            withAnimation(.easeInOut(duration: 0.65)) {
                fillFraction = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                action()
                withAnimation(.none) { fillFraction = 0 }
                filling = false
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.lg)
                    .fill(borderColor.opacity(0.10))

                WaterShape(fillFraction: fillFraction, phase: phase)
                    .fill(
                        LinearGradient(
                            colors: [waterBottom, waterTop],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: Radius.lg))

                Label("Start cleaning", systemImage: "hands.sparkles.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(fillFraction > 0.45 ? .white : borderColor)
                    .animation(.easeInOut(duration: 0.15), value: fillFraction > 0.45)
            }
            .frame(minWidth: 240, minHeight: 56)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(
                        borderColor.opacity(disabled ? 0.2 : 0.65),
                        lineWidth: 1.5
                    )
            )
            .shadow(
                color: borderColor.opacity(fillFraction * 0.45),
                radius: 14, y: 5
            )
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.45 : 1.0)
    }
}
