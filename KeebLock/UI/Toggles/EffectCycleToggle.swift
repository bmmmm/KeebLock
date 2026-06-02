import SwiftUI

// Launcher card that cycles through effect types on each tap.
// Tapping when off → enables + sparks. Tapping through all effects → off again.
struct EffectCycleToggle: View {
    @ObservedObject var settings: AppSettings

    private var isActive: Bool { settings.effectEnabled }
    private var effect: ScreenEffect { settings.screenEffect }
    private var cardIcon: String { isActive ? effect.icon : "circle.slash" }
    private var cardLabel: String { isActive ? effect.label : "None" }
    private var effectKey: String { isActive ? effect.rawValue : "off" }

    var body: some View {
        LauncherChip(label: cardLabel, activeColor: effect.activeColor, isActive: isActive, action: cycleEffect) {
            Image(systemName: cardIcon)
                .font(.system(size: 24, weight: .medium))
                .symbolEffect(.bounce, value: effectKey)
        }
        // Crossfade the icon/label/tint when cycling between active effects
        // (isActive stays true, so the chip's own animation doesn't cover it).
        .animation(.spring(response: 0.28, dampingFraction: 0.58), value: effect)
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
