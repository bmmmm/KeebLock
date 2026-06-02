import SwiftUI

// Generic icon-on-card toggle used for the launcher's "vibes" panel
// (Sound, Sparks, etc.).
struct GameModeToggle: View {
    let icon: String
    let label: String
    let activeColor: Color
    @Binding var isOn: Bool

    var body: some View {
        LauncherChip(label: label, activeColor: activeColor, isActive: isOn, action: { isOn.toggle() }) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .symbolEffect(.bounce, value: isOn)
        }
    }
}
