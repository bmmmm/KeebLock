import SwiftUI

extension SettingsView {
    var pixelSection: some View {
        tintedSection("Pixel size") {
            HStack(spacing: 12) {
                Image(systemName: "square.fill")
                    .font(.system(size: 18 * uiScale))
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(settings.pixelFineness) },
                        set: { settings.pixelFineness = Int($0.rounded()) }
                    ),
                    in: 1...10,
                    step: 1
                )
                Image(systemName: "square.grid.4x3.fill")
                    .font(.system(size: 12 * uiScale))
                    .foregroundStyle(.secondary)
                Text("\(settings.pixelFineness)")
                    .font(scaled(17, mono: true))
                    .frame(width: 22, alignment: .trailing)
            }

            PixelSizePreview(
                cellsX: settings.cellsPerAxis,
                backgroundPreset: settings.backgroundColor,
                pixelPreset: settings.pixelColor
            )

            Text("Lower = bigger pixel blocks, faster stages. Higher = smaller pixels, longer stages.")
                .font(fCaption)
                .foregroundStyle(.secondary)
        }
    }

    var colorsSection: some View {
        tintedSection("Colors") {
            Text("Two layers: the **background** is what you see initially; the **pixel** layer is what's revealed when a cell gets wiped. Default is colored bg → transparent pixel (desktop shows through). Swap them for an invert / dirty mode.")
                .font(fCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            colorRow(label: "Background", binding: $settings.backgroundColor)
            colorRow(label: "Pixel",      binding: $settings.pixelColor)

            HStack {
                Spacer()
                Button {
                    settings.swapColors()
                } label: {
                    Label("Swap (invert)", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    func colorRow(label: String, binding: Binding<ColorPreset>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(scaled(14, .semibold))
            HStack(spacing: 6) {
                ForEach(ColorPreset.allCases) { preset in
                    presetSwatch(preset, isSelected: binding.wrappedValue == preset) {
                        binding.wrappedValue = preset
                    }
                }
            }
        }
    }

    func presetSwatch(_ preset: ColorPreset, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                presetSwatchFill(preset)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(scaled(13, .bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(isSelected ? settings.appTheme.color : .secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(preset.label)
    }

    @ViewBuilder
    func presetSwatchFill(_ preset: ColorPreset) -> some View {
        switch preset {
        case .random:
            LinearGradient.presetRainbow
        case .transparent:
            ZStack {
                Color.gray.opacity(0.25)
                Path { p in
                    p.move(to: .init(x: 0, y: 28))
                    p.addLine(to: .init(x: 28, y: 0))
                }
                .stroke(Color.red, lineWidth: 2)
            }
        default:
            preset.swiftUIColor
        }
    }
}
