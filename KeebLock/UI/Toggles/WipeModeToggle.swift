import SwiftUI

// Launcher card that cycles between wipe modes (random ↔ positional).
// Wipe mode has no "off" state — wiping always happens during a lock —
// so the card stays visually active and only the icon/label/tint change
// to reflect which mode the next session will use.
struct WipeModeToggle: View {
    @ObservedObject var settings: AppSettings

    private var mode: WipeMode { settings.wipeMode }

    var body: some View {
        // Wipe is always active (no "off" mode), so isActive is fixed true —
        // the card stays at full tint/scale and only the icon/label/tint cycle.
        LauncherChip(label: mode.label, activeColor: mode.activeColor, isActive: true, action: cycleMode) {
            Image(systemName: mode.icon)
                .font(.system(size: 24, weight: .medium))
                .symbolEffect(.bounce, value: mode)
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.58), value: mode)
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
