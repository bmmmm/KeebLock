import SwiftUI

// Launcher chip for picking the BACKGROUND color preset only. The pixel color
// is kept in Settings (less commonly tweaked from the launcher).
struct ColorModeToggle: View {
    @ObservedObject var settings: AppSettings
    @State private var showSwatches = false

    private var preset: ColorPreset { settings.backgroundColor }
    private var isCustom: Bool { preset != .random }

    var body: some View {
        LauncherChip(label: preset.label, activeColor: cardBg, isActive: isCustom, action: { showSwatches = true }) {
            swatch
        }
        .popover(isPresented: $showSwatches, arrowEdge: .bottom) {
            picker
        }
    }

    @ViewBuilder
    private var swatch: some View {
        switch preset {
        case .random:
            LinearGradient.presetRainbow
            .frame(width: 26, height: 26)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
        case .transparent:
            ZStack {
                Color.white.opacity(0.25)
                Path { p in
                    p.move(to: .init(x: 0, y: 26))
                    p.addLine(to: .init(x: 26, y: 0))
                }
                .stroke(Color.red, lineWidth: 2)
            }
            .frame(width: 26, height: 26)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
        default:
            Circle()
                .fill(preset.swiftUIColor)
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: 1.5))
                .frame(width: 26, height: 26)
        }
    }

    private var cardBg: Color {
        switch preset {
        case .random:      return Color(red: 0.55, green: 0.45, blue: 0.85)
        case .transparent: return Color.gray.opacity(0.35)
        default:           return preset.swiftUIColor
        }
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Background Color")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 5), spacing: 10) {
                ForEach(ColorPreset.allCases) { p in
                    swatchButton(for: p)
                }
            }
        }
        .padding(16)
        .frame(width: 240)
    }

    private func swatchButton(for p: ColorPreset) -> some View {
        let selected = (preset == p)
        return Button {
            settings.backgroundColor = p
            showSwatches = false
        } label: {
            ZStack {
                presetSwatchFill(p)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                }
            }
            .frame(width: 36, height: 36)
            .clipShape(Circle())
            .overlay(
                Circle().strokeBorder(selected ? settings.appTheme.color : .clear, lineWidth: 2)
            )
            .scaleEffect(selected ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .help(p.label)
    }

    @ViewBuilder
    private func presetSwatchFill(_ p: ColorPreset) -> some View {
        switch p {
        case .random:
            LinearGradient.presetRainbow
        case .transparent:
            ZStack {
                Color.gray.opacity(0.25)
                Path { path in
                    path.move(to: .init(x: 0, y: 36))
                    path.addLine(to: .init(x: 36, y: 0))
                }
                .stroke(Color.red, lineWidth: 2)
            }
        default:
            p.swiftUIColor
        }
    }
}
