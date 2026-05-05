import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: LockController
    @ObservedObject var history: CleaningHistory = .shared

    @State private var suggestions: [String] = Codewords.suggestions()
    @State private var showHeatmap = false
    @State private var showHistory = false
    @State private var snapshotMessage: String?

    var body: some View {
        Form {
            codewordSection
            pixelSection
            colorsSection
            effectSection
            soundSection
            knowledgeSection
            heatmapSection
            historySection
            autoUnlockSection
            aboutSection
            debugSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 540, minHeight: 640)
        .sheet(isPresented: $showHeatmap) {
            HeatmapView(controller: controller)
        }
        .sheet(isPresented: $showHistory) {
            CleaningHistoryView(history: history)
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

    private var pixelSection: some View {
        Section("Pixel size") {
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

            PixelSizePreview(
                cellsX: settings.cellsPerAxis,
                backgroundPreset: settings.backgroundColor,
                pixelPreset: settings.pixelColor
            )

            Text("Lower = bigger pixel blocks, faster stages. Higher = smaller pixels, longer stages.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var colorsSection: some View {
        Section("Colors") {
            Text("Two layers: the **background** is what you see initially; the **pixel** layer is what's revealed when a cell gets wiped. Default is colored bg → transparent pixel (desktop shows through). Swap them for an invert / dirty mode.")
                .font(.caption)
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

    private func colorRow(label: String, binding: Binding<ColorPreset>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.semibold))
            HStack(spacing: 6) {
                ForEach(ColorPreset.allCases) { preset in
                    presetSwatch(preset, isSelected: binding.wrappedValue == preset) {
                        binding.wrappedValue = preset
                    }
                }
            }
        }
    }

    private func presetSwatch(_ preset: ColorPreset, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                presetSwatchFill(preset)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor : .secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(preset.label)
    }

    @ViewBuilder
    private func presetSwatchFill(_ preset: ColorPreset) -> some View {
        switch preset {
        case .random:
            LinearGradient(
                colors: [.pink, .yellow, .green, .blue, .purple],
                startPoint: .leading, endPoint: .trailing
            )
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

    private var effectSection: some View {
        Section("Effect") {
            Toggle("Enable effect on keystroke", isOn: $settings.effectEnabled)
            if settings.effectEnabled {
                Picker("Type", selection: $settings.screenEffect) {
                    ForEach(ScreenEffect.allCases) { effect in
                        Label(effect.label, systemImage: effect.icon).tag(effect)
                    }
                }
                .pickerStyle(.segmented)

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
                Text("Intensity per keystroke. 0 = off, 30 = max.")
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

    private var knowledgeSection: some View {
        Section("Codeword knowledge") {
            Toggle("Show on launcher and lock screen", isOn: $settings.showCodewordKnowledge)
            Text("Curated geology summary plus 10 facts per codeword. Hover the ghost icons on the launcher to reveal each fact, or read them rotating in the lock screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var historySection: some View {
        Section("Cleaning history") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Past sessions")
                        .font(.body)
                    if let last = history.lastWipe {
                        Text("Last wipe: \(formatDate(last))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No sessions recorded yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button {
                    showHistory = true
                } label: {
                    Label("View", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(history.sessions.isEmpty)
            }
        }
    }

    private var autoUnlockSection: some View {
        Section("Auto-unlock") {
            Toggle("Enable automatic timeout", isOn: $settings.autoUnlockEnabled)
            if settings.autoUnlockEnabled {
                Picker("Duration", selection: $settings.durationMinutes) {
                    Text("3 minutes").tag(3)
                    Text("5 minutes").tag(5)
                    Text("10 minutes").tag(10)
                }
                .pickerStyle(.segmented)
            }
            Text("Off by default. Without this, the lock stays active until you type the codeword or click \"Unlock now\". Force-quit (⌘⌥Esc) is always the safety net.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        Section("About") {
            Text("KeebLock swallows keystrokes via macOS Accessibility while you wipe down your keys. Type your codeword (substring match) or click \"Unlock now\" to exit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var debugSection: some View {
        Section("Debug") {
            Toggle("Enable debug logging", isOn: $settings.debugLoggingEnabled)

            HStack(spacing: 10) {
                Button("Save snapshot") {
                    let snap = DebugLog.snapshot()
                    DebugLog.writeForced(snap)
                    snapshotMessage = "Snapshot appended to log."
                }
                .buttonStyle(.bordered)

                Button("Copy all debug info") {
                    let snap = DebugLog.snapshot()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snap, forType: .string)
                    snapshotMessage = "Copied to clipboard."
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

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
