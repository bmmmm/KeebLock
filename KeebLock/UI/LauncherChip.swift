import SwiftUI

/// Shared launcher "vibes" card. The four launcher toggles (Game/Sound, Effect,
/// Color, Wipe) copy-pasted this exact body — height 84, a continuous rounded
/// rect with a tinted fill + drop shadow when active, a centred icon-over-label
/// stack — and had already drifted (WipeModeToggle was missing the inactive
/// `scaleEffect`, and its activate spring was 0.22/0.55 vs the others'
/// 0.28/0.58). Each toggle now supplies only its icon, label, tint, and action;
/// the chrome lives here once.
///
/// `isActive` drives the fill (tint vs subtle surface), the white-vs-secondary
/// foreground, and the 0.96 rest-scale. Always-on cards (Wipe — wiping has no
/// "off" state) pass `isActive: true`, so they sit at full scale and full tint.
/// Cards that also change appearance while staying active (Effect cycling its
/// type, Wipe cycling its mode) add their own `.animation(..., value:)` for
/// that transition on top of this one.
struct LauncherChip<Icon: View>: View {
    let label: String
    let activeColor: Color
    let isActive: Bool
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.sm) {
                icon()
                Text(label)
                    .font(.caption.weight(.bold))
                    .tracking(0.3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background {
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(isActive ? activeColor : Color.surfaceSubtle)
                    .shadow(color: isActive ? activeColor.opacity(0.45) : .clear, radius: 10, y: 5)
            }
            .foregroundStyle(isActive ? .white : Color.secondary)
            .contentShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isActive ? 1.0 : 0.96)
        .animation(.spring(response: 0.28, dampingFraction: 0.58), value: isActive)
    }
}
