import SwiftUI

// Launcher card that cycles between wipe modes (random ↔ positional).
// Wipe mode has no "off" state — wiping always happens during a lock —
// so the card stays visually active and only the icon/label/tint change
// to reflect which mode the next session will use.
struct WipeModeToggle: View {
    @ObservedObject var settings: AppSettings

    private var mode: WipeMode { settings.wipeMode }

    var body: some View {
        Button { cycleMode() } label: {
            VStack(spacing: 9) {
                Image(systemName: mode.icon)
                    .font(.system(size: 24, weight: .medium))
                    .symbolEffect(.bounce, value: mode)
                Text(mode.label)
                    .font(.caption.weight(.bold))
                    .tracking(0.3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(mode.activeColor)
                    .shadow(color: mode.activeColor.opacity(0.45), radius: 10, y: 5)
            }
            .foregroundStyle(.white)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.22, dampingFraction: 0.55), value: mode)
    }

    private func cycleMode() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
            let all = WipeMode.allCases
            if let idx = all.firstIndex(of: mode), idx + 1 < all.count {
                settings.wipeMode = all[idx + 1]
            } else {
                settings.wipeMode = all[0]
            }
        }
    }
}
