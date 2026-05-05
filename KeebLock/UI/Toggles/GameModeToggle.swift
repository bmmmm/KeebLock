import SwiftUI

// Generic icon-on-card toggle used for the launcher's "vibes" panel
// (Sound, Sparks, etc.).
struct GameModeToggle: View {
    let icon: String
    let label: String
    let activeColor: Color
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                isOn.toggle()
            }
        } label: {
            VStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .medium))
                    .symbolEffect(.bounce, value: isOn)
                Text(label)
                    .font(.caption.weight(.bold))
                    .tracking(0.3)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 84)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isOn ? activeColor : Color.primary.opacity(0.06))
                    .shadow(color: isOn ? activeColor.opacity(0.45) : .clear, radius: 10, y: 5)
            }
            .foregroundStyle(isOn ? .white : Color.secondary)
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isOn ? 1.0 : 0.96)
        .animation(.spring(response: 0.28, dampingFraction: 0.58), value: isOn)
    }
}
