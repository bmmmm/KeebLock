import SwiftUI

extension SettingsView {
    var themeSection: some View {
        tintedSection("Theme") {
            HStack(spacing: 14) {
                ForEach(AppTheme.allCases) { theme in
                    themeChip(theme)
                }
                Spacer(minLength: 12)
                themePreview
            }
            .padding(.vertical, 4)
            Text("Tints the entire app. Light/Dark mode follows your system. Drag the window edge to resize — the launcher and settings text scale to fit; it can't be shrunk below a readable floor. Doesn't affect the lock screen.")
                .font(fCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Three-element live sample — same colour applied as icon tint, as
    /// border+foreground, and as fill — so the user can see at a glance
    /// how the chosen theme reads across the typical roles SwiftUI's
    /// `.tint` ends up in (text accents, outlined controls, filled buttons).
    /// Animated together with the chip selection.
    var themePreview: some View {
        let c = settings.appTheme.color
        return HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 18 * uiScale, weight: .semibold))
                .foregroundStyle(c)

            Text("Aa")
                .font(scaled(14, .semibold, mono: true))
                .foregroundStyle(c)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .strokeBorder(c, lineWidth: 1.2)
                )

            Text("Action")
                .font(scaled(13, .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(c))
        }
        .animation(.easeInOut(duration: 0.25), value: settings.appTheme)
    }

    func themeChip(_ theme: AppTheme) -> some View {
        let selected = settings.appTheme == theme
        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.65)) {
                settings.appTheme = theme
            }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(theme.color)
                        .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
                    if selected {
                        Image(systemName: "checkmark")
                            .font(scaled(14, .bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                    } else {
                        Image(systemName: theme.icon)
                            .font(scaled(13, .bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .frame(width: 36, height: 36)
                .scaleEffect(selected ? 1.08 : 1.0)

                Text(theme.label)
                    .font(scaled(13, .semibold))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(theme.label)
    }
}
