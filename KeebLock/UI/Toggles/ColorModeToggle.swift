import SwiftUI

// Color preset picker — the third card on the launcher's "vibes" panel. Tapping
// when off opens a popover with preset swatches; tapping when on clears the
// custom color (back to random per stage).
struct ColorModeToggle: View {
    @ObservedObject var settings: AppSettings
    @State private var showSwatches = false

    static let presets: [(name: String, rgb: [Double])] = [
        ("Rose",     [1.00, 0.71, 0.76]),
        ("Lavender", [0.73, 0.60, 0.98]),
        ("Mint",     [0.62, 0.96, 0.78]),
        ("Sky",      [0.60, 0.85, 1.00]),
        ("Peach",    [1.00, 0.78, 0.60]),
        ("Lemon",    [1.00, 0.96, 0.52]),
        ("Coral",    [1.00, 0.60, 0.60]),
        ("Lilac",    [0.82, 0.65, 1.00]),
    ]

    private var isOn: Bool { settings.customScreenColorRGB != nil }
    private var activeColor: Color { settings.customSwiftUIColor }

    var body: some View {
        Button {
            if isOn {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) {
                    settings.customScreenColorRGB = nil
                }
            } else {
                showSwatches = true
            }
        } label: {
            VStack(spacing: 9) {
                if isOn {
                    Circle()
                        .fill(activeColor)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1.5))
                } else {
                    Image(systemName: "paintpalette.fill")
                        .font(.system(size: 24, weight: .medium))
                }
                Text("Color")
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
        .popover(isPresented: $showSwatches, arrowEdge: .bottom) {
            swatchGrid
        }
    }

    private var swatchGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Screen Color")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40)), count: 4), spacing: 10) {
                ForEach(Self.presets, id: \.name) { preset in
                    let color = Color(red: preset.rgb[0], green: preset.rgb[1], blue: preset.rgb[2])
                    let selected = settings.customScreenColorRGB == preset.rgb
                    Button {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                            settings.customScreenColorRGB = preset.rgb
                        }
                        showSwatches = false
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 36, height: 36)
                            .overlay {
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .shadow(color: color.opacity(0.4), radius: 4, y: 2)
                            .scaleEffect(selected ? 1.1 : 1.0)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
    }
}
