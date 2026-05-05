import SwiftUI

// Launcher card that cycles through effect types on each tap.
// Tapping when off → enables + sparks. Tapping through all effects → off again.
struct EffectCycleToggle: View {
    @ObservedObject var settings: AppSettings

    private var isActive: Bool { settings.effectEnabled }
    private var effect: ScreenEffect { settings.screenEffect }
    private var cardIcon: String { isActive ? effect.icon : "circle.slash" }
    private var cardLabel: String { isActive ? effect.label : "None" }
    private var cardColor: Color { isActive ? effect.activeColor : Color.primary.opacity(0.06) }
    private var effectKey: String { isActive ? effect.rawValue : "off" }

    var body: some View {
        Button { cycleEffect() } label: {
            VStack(spacing: 9) {
                Image(systemName: cardIcon)
                    .font(.system(size: 24, weight: .medium))
                    .symbolEffect(.bounce, value: effectKey)
                Text(cardLabel)
                    .font(.caption.weight(.bold))
                    .tracking(0.3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isActive ? effect.activeColor : Color.primary.opacity(0.06))
                    .shadow(color: isActive ? effect.activeColor.opacity(0.45) : .clear, radius: 10, y: 5)
            }
            .foregroundStyle(isActive ? .white : Color.secondary)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isActive ? 1.0 : 0.96)
        .animation(.spring(response: 0.28, dampingFraction: 0.58), value: isActive)
        .animation(.spring(response: 0.22, dampingFraction: 0.55), value: effect)
    }

    private func cycleEffect() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
            if !settings.effectEnabled {
                settings.effectEnabled = true
                settings.screenEffect = .sparks
            } else {
                let all = ScreenEffect.allCases
                if let idx = all.firstIndex(of: settings.screenEffect), idx + 1 < all.count {
                    settings.screenEffect = all[idx + 1]
                } else {
                    settings.effectEnabled = false
                }
            }
        }
    }
}
