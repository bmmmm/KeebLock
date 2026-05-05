import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: LockController

    @State private var suggestions: [String] = Codewords.suggestions()
    @State private var showHeatmap = false
    @State private var snapshotMessage: String?

    var body: some View {
        Form {
            codewordSection
            durationSection
            pixelSection
            sparksSection
            soundSection
            heatmapSection
            debugSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 720)
        .sheet(isPresented: $showHeatmap) {
            HeatmapView(controller: controller)
        }
    }

    // MARK: - Sections

    private var codewordSection: some View {
        Section("Codeword") {
            TextField("Codeword", text: $settings.codeword)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack {
                Text("Suggestions (geology)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Roll new") { suggestions = Codewords.suggestions() }
                    .buttonStyle(.borderless)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 110), spacing: 8)],
                spacing: 8
            ) {
                ForEach(suggestions, id: \.self) { word in
                    Button(word) { settings.codeword = word }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var durationSection: some View {
        Section("Auto-unlock") {
            Picker("Duration", selection: $settings.durationMinutes) {
                Text("3 minutes").tag(3)
                Text("5 minutes").tag(5)
                Text("10 minutes").tag(10)
            }
            .pickerStyle(.segmented)
        }
    }

    private var pixelSection: some View {
        Section("Pixels") {
            // Size slider
            HStack(spacing: 12) {
                Image(systemName: "square.fill")
                    .font(.system(size: 18))
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
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("\(settings.pixelFineness)")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 22, alignment: .trailing)
            }

            // Live preview
            PixelSizePreview(
                cellsX: settings.cellsPerAxis,
                color: previewColor
            )
            .frame(height: 80)

            Text("Lower = bigger pixel blocks, faster stages. Higher = smaller pixels, longer stages.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            // Color picker
            colorPickerRow
        }
    }

    private var previewColor: Color {
        if let c = settings.customSwiftUIColor as Color?,
           settings.customScreenColorRGB != nil {
            return c
        }
        return Color(hue: 0.6, saturation: 0.65, brightness: 0.55)
    }

    private var colorPickerRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { settings.customScreenColorRGB != nil },
                set: { isOn in
                    if isOn {
                        settings.customScreenColorRGB = settings.customScreenColorRGB ?? [0.6, 0.7, 0.95]
                    } else {
                        settings.customScreenColorRGB = nil
                    }
                }
            )) {
                Text("Use fixed color (off = random per stage)")
            }

            if settings.customScreenColorRGB != nil {
                ColorPicker("Pixel color",
                    selection: Binding(
                        get: { settings.customSwiftUIColor },
                        set: { color in
                            let cg = NSColor(color).usingColorSpace(.sRGB) ?? .white
                            settings.customScreenColorRGB = [
                                Double(cg.redComponent),
                                Double(cg.greenComponent),
                                Double(cg.blueComponent),
                            ]
                        }
                    ),
                    supportsOpacity: false
                )
            }
        }
    }

    private var sparksSection: some View {
        Section("Sparks") {
            Toggle("Show sparks on keystroke", isOn: $settings.sparksEnabled)
            if settings.sparksEnabled {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(settings.sparkCount) },
                            set: { settings.sparkCount = Int($0.rounded()) }
                        ),
                        in: 0...30,
                        step: 1
                    )
                    Image(systemName: "sparkles")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                    Text("\(settings.sparkCount)")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 28, alignment: .trailing)
                }
                Text("Sparks per keystroke. 0 = silent, 30 = max splash.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var soundSection: some View {
        Section("Sound") {
            Toggle("Play click on keystroke", isOn: $settings.soundEnabled)
            if settings.soundEnabled {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.1")
                    Slider(value: $settings.soundVolume, in: 0...1)
                    Image(systemName: "speaker.wave.3")
                    Text("\(Int(settings.soundVolume * 100))%")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 40, alignment: .trailing)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(settings.soundFileDisplayName ?? "Synthesized click (default)")
                            .font(.callout)
                        Text(settings.soundFileBookmark != nil ? "Custom audio file" : "Built-in")
                            .font(.caption)
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

    private var heatmapSection: some View {
        Section("Heatmap") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accumulated keystroke data")
                        .font(.body)
                    Text("\(controller.keyCounts.values.reduce(0, +)) presses across \(controller.keyCounts.count) keys")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showHeatmap = true
                } label: {
                    Label("View", systemImage: "chart.bar.fill")
                }
                .buttonStyle(.bordered)
                .disabled(controller.keyCounts.isEmpty)
            }
        }
    }

    private var debugSection: some View {
        Section("Debug") {
            Toggle("Enable debug logging", isOn: $settings.debugLoggingEnabled)

            HStack(spacing: 10) {
                Button("Save diagnostic snapshot") {
                    let snap = DebugLog.snapshot()
                    DebugLog.writeForced(snap)
                    snapshotMessage = "Snapshot appended."
                }
                .buttonStyle(.bordered)

                Button("Reveal log") {
                    DebugLog.revealLogInFinder()
                }
                .buttonStyle(.bordered)
            }

            if let snapshotMessage {
                Text(snapshotMessage)
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Text("Log path: ~/Library/Logs/KeebLock/keeblock.log")
                .font(.caption)
                .foregroundStyle(.secondary)

            if settings.debugLoggingEnabled {
                DebugInfoPanel(settings: settings, controller: controller)
                    .padding(.top, 8)
            }
        }
    }

    private var aboutSection: some View {
        Section("About") {
            Text("KeebLock swallows keystrokes via macOS Accessibility while you wipe down your keys. Type your codeword (substring match) or click \"Unlock now\" to exit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func pickSoundFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose a sound for keystrokes"
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
