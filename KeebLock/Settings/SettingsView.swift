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
    @State private var codewordEditing = false
    @FocusState private var codewordFocused: Bool

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
            // Animated display/edit card
            ZStack {
                if codewordEditing {
                    TextField("codeword", text: $settings.codeword)
                        .font(.system(size: 22, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .focused($codewordFocused)
                        .onSubmit { withAnimation(.spring(response: 0.3)) { codewordEditing = false } }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.accentColor.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.accentColor, lineWidth: 1.5)
                                )
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    Button {
                        withAnimation(.spring(response: 0.3)) { codewordEditing = true }
                        codewordFocused = true
                    } label: {
                        HStack(spacing: 12) {
                            Text(settings.codeword.uppercased())
                                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                                .tracking(2)
                                .foregroundStyle(.primary)
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.primary.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: codewordEditing)

            HStack {
                Text("Suggestions — geology")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35)) {
                        suggestions = Codewords.suggestions()
                    }
                } label: {
                    Label("Roll new", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 100), spacing: 6)],
                spacing: 6
            ) {
                ForEach(suggestions, id: \.self) { word in
                    Button {
                        settings.codeword = word
                        withAnimation(.spring(response: 0.3)) { codewordEditing = false }
                    } label: {
                        Text(word)
                            .font(.system(.callout, design: .monospaced))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                settings.codeword == word
                                ? RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.15))
                                : RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        settings.codeword == word ? Color.accentColor.opacity(0.5) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                            .foregroundStyle(settings.codeword == word ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.25), value: settings.codeword)
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
                    Image(systemName: settings.screenEffect.sliderLeftIcon)
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
                    Image(systemName: settings.screenEffect.sliderRightIcon)
                        .font(.system(size: 15))
                        .foregroundStyle(settings.screenEffect.activeColor)
                    Text("\(settings.sparkCount)")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 28, alignment: .trailing)
                }
                Text(settings.screenEffect.intensityDescription + " (0 = off, 30 = max)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .animation(.easeInOut(duration: 0.2), value: settings.screenEffect)
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
            HStack(spacing: 14) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("KeebLock")
                        .font(.headline)
                    Text("Version \(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text("Swallows keystrokes via macOS Accessibility while you wipe down your keys. Type the codeword (suffix-match) to escape — or click \"Unlock now\" once you're half-way through.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Link(destination: URL(string: "https://github.com/bmmmm")!) {
                    Label("@bmmmm", systemImage: "person.circle")
                        .font(.callout)
                }

                Divider().frame(height: 16)

                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Project repo coming soon")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.borderless)

            Divider()

            // Support / donation
            Link(destination: URL(string: "https://ko-fi.com/bmabma?utm_source=keeblock&utm_medium=desktop_app")!) {
                HStack(spacing: 8) {
                    Image(systemName: "cup.and.saucer.fill")
                        .foregroundStyle(.pink)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Support development on Ko-fi")
                            .font(.callout.weight(.semibold))
                        Text("ko-fi.com/bmabma")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Divider()

            // Content attribution — required when shipping CC-BY-SA Wikimedia images
            VStack(alignment: .leading, spacing: 4) {
                Text("Content credits")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text("Codeword summaries and facts:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Wikipedia", destination: URL(string: "https://en.wikipedia.org")!)
                        .font(.caption)
                }
                HStack(spacing: 4) {
                    Text("Lead images:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Wikimedia Commons", destination: URL(string: "https://commons.wikimedia.org")!)
                        .font(.caption)
                    Text("(CC-BY-SA)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("To uninstall: open **KeebLock.app/Contents/Resources/** in Finder and run **Uninstall KeebLock.command**, or run `scripts/uninstall.sh` from the project directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 2)
        }
    }

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
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
