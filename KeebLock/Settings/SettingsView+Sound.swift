import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SettingsView {
    var soundSection: some View {
        tintedSection("Sound") {
            Toggle("Play click on wipe", isOn: $settings.soundEnabled)
            Toggle("Chime when unlocked", isOn: $settings.unlockChimeEnabled)
            if settings.soundEnabled {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.1")
                    Slider(value: $settings.soundVolume, in: 0...2.0)
                    Image(systemName: "speaker.wave.3")
                        .foregroundStyle(settings.soundVolume > 1.0 ? .red : .primary)
                    Text(volumeLabel)
                        .font(scaled(17, mono: true))
                        .foregroundStyle(settings.soundVolume > 1.0 ? .red : .primary)
                        .frame(width: 64, alignment: .trailing)
                }
                if settings.soundVolume > 1.0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Overdrive — output is clipping. Lower for clean audio.")
                            .font(fCaption)
                            .foregroundStyle(.red)
                    }
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.soundFileDisplayName ?? "Synthesized click (default)")
                            .font(fCallout)
                        Text(settings.soundFileBookmark != nil ? "Custom audio file" : "Built-in")
                            .font(fCaption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose file…") { pickSoundFile() }
                        .buttonStyle(.bordered)
                    if settings.soundFileBookmark != nil {
                        Button("Reset") {
                            settings.soundFileBookmark = nil
                            settings.soundFileDisplayName = nil
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    /// Slider label: dB scale because amplitude perception is logarithmic.
    /// 100 % = 0 dB (full output), 50 % ≈ −6 dB, 10 % ≈ −20 dB,
    /// 200 % ≈ +6 dB (overdrive). 0 % shows −∞ to make it obvious the
    /// click is silent rather than just quiet. Positive values are
    /// signed to make the overdrive zone unambiguous.
    var volumeLabel: String {
        if settings.soundVolume <= 0.001 { return "−∞ dB" }
        let db = 20 * log10(settings.soundVolume)
        return String(format: "%+.0f dB", db)
    }

    func pickSoundFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a sound for wipes"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .wav, .mp3, .mpeg4Audio, .aiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            settings.soundFileBookmark = bookmark
            settings.soundFileDisplayName = url.lastPathComponent
        } catch {
            DebugLog.log("Sound file picker: bookmark failed: \(error.localizedDescription)")
        }
    }
}
