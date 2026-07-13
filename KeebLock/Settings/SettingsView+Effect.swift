import SwiftUI

extension SettingsView {
    var wipeModeSection: some View {
        tintedSection("Wipe mode") {
            Picker("Mode", selection: $settings.wipeMode) {
                ForEach(WipeMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.wipeMode.helpText)
                .font(fCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.2), value: settings.wipeMode)

            Divider()

            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 12 * uiScale))
                    .foregroundStyle(.secondary)
                Slider(
                    value: $settings.stageAdvanceThreshold,
                    in: 0.80...1.00,
                    step: 0.01
                )
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14 * uiScale))
                    .foregroundStyle(.secondary)
                Text("\(Int(settings.stageAdvanceThreshold * 100))%")
                    .font(scaled(17, mono: true))
                    .frame(width: 44, alignment: .trailing)
            }
            Text("Stage advances once this fraction of cells is wiped. Lower if certain keys (e.g. F3/F4 system actions the OS swallows) prevent reaching 100%.")
                .font(fCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var effectSection: some View {
        tintedSection("Effect") {
            Toggle("Enable effect on wipe", isOn: $settings.effectEnabled)
            if settings.effectEnabled {
                Picker("Type", selection: $settings.screenEffect) {
                    ForEach(ScreenEffect.allCases) { effect in
                        Label(effect.label, systemImage: effect.icon).tag(effect)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 12) {
                    Image(systemName: settings.screenEffect.sliderLeftIcon)
                        .font(.system(size: 12 * uiScale))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(settings.sparkCount) },
                            set: { settings.sparkCount = Int($0.rounded()) }
                        ),
                        in: 0...30,
                        step: 1
                    )
                    Image(systemName: settings.screenEffect.sliderRightIcon)
                        .font(.system(size: 15 * uiScale))
                        .foregroundStyle(settings.screenEffect.activeColor)
                    Text("\(settings.sparkCount)")
                        .font(scaled(17, mono: true))
                        .frame(width: 28, alignment: .trailing)
                }
                Text(settings.screenEffect.intensityDescription + " (0 = off, 30 = max)")
                    .font(fCaption)
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut(duration: 0.2), value: settings.screenEffect)
            }
        }
    }
}
