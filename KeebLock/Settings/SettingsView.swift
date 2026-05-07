import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var controller: LockController
    @ObservedObject var history: CleaningHistory = .shared

    @State private var suggestions: [String] = Codewords.suggestions()
    @State private var showCleanmap = false
    @State private var showHistory = false
    @State private var snapshotMessage: String?
    @State private var copiedCommand: String?
    @State private var codewordEditing = false
    @FocusState private var codewordFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                codewordSection
                themeSection
                pixelSection
                wipeModeSection
                colorsSection
                effectSection
                soundSection
                knowledgeSection
                cleanmapSection
                historySection
                autoUnlockSection
                aboutSection
                debugSection
            }
            .formStyle(.grouped)
            .onChange(of: settings.debugLoggingEnabled) { _, enabled in
                guard enabled else { return }
                // Defer one runloop tick so the conditional sub-views in
                // debugSection are already in the layout before we scroll —
                // otherwise the destination is the *old* debugSection end.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(Self.debugBottomID, anchor: .bottom)
                    }
                }
            }
            .sheet(isPresented: $showCleanmap) {
                CleanmapView(controller: controller)
            }
            .sheet(isPresented: $showHistory) {
                CleaningHistoryView(history: history)
            }
        }
    }

    private static let debugBottomID = "keeblock.settings.debug.bottom"

    private let uninstallCommands = [
        "open '/Applications/KeebLock.app/Contents/Resources/'",
        "scripts/uninstall.sh",
    ]

    // MARK: - Sections

    /// Wraps SwiftUI's stock `Section(_:content:)` with a tinted header so
    /// the group title picks up the active theme accent. The Section's
    /// own grouped-form styling is otherwise untouched, so the row layout
    /// inside stays identical to the default look.
    @ViewBuilder
    private func tintedSection<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Section {
            content()
        } header: {
            Text(title).foregroundStyle(.tint)
        }
    }

    private var codewordSection: some View {
        tintedSection("Codeword") {
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
                                .fill(settings.appTheme.color.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(settings.appTheme.color, lineWidth: 1.5)
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
                                ? RoundedRectangle(cornerRadius: 8).fill(settings.appTheme.color.opacity(0.15))
                                : RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(
                                        settings.codeword == word ? settings.appTheme.color.opacity(0.5) : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                            .foregroundStyle(settings.codeword == word ? settings.appTheme.color : .primary)
                    }
                    .buttonStyle(.plain)
                    .animation(.spring(response: 0.25), value: settings.codeword)
                }
            }
        }
    }

    private var pixelSection: some View {
        tintedSection("Pixel size") {
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

    private var wipeModeSection: some View {
        tintedSection("Wipe mode") {
            Picker("Mode", selection: $settings.wipeMode) {
                ForEach(WipeMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(settings.wipeMode.helpText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .animation(.easeInOut(duration: 0.2), value: settings.wipeMode)
        }
    }

    private var colorsSection: some View {
        tintedSection("Colors") {
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
                    .strokeBorder(isSelected ? settings.appTheme.color : .secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
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
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(settings.soundVolume > 1.0 ? .red : .primary)
                        .frame(width: 64, alignment: .trailing)
                }
                if settings.soundVolume > 1.0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Overdrive — output is clipping. Lower for clean audio.")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
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

    private var themeSection: some View {
        tintedSection("Theme") {
            HStack(spacing: 14) {
                ForEach(AppTheme.allCases) { theme in
                    themeChip(theme)
                }
                Spacer(minLength: 12)
                themePreview
            }
            .padding(.vertical, 4)
            Text("Tints the entire app. Light/Dark mode follows your system.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            // App-zoom indicator. No slider — the slider was a UX trap
            // because dynamic-type-based scaling under-amplifies native
            // AppKit controls on macOS, so the slider felt unresponsive.
            // The new mechanism is a scaleEffect zoom on the whole window,
            // controlled exclusively via ⌘+ / ⌘− / ⌘0 from the View menu.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("App zoom")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int((settings.appZoom * 100).rounded())) %")
                    .font(.system(.body, design: .monospaced))
                Button("Reset") {
                    settings.appZoom = 1.0
                }
                .buttonStyle(.borderless)
                .disabled(abs(settings.appZoom - 1.0) < 0.001)
            }
            Text("Visual zoom for the entire KeebLock window — launcher and settings together. Use ⌘+ / ⌘− to step in 10 % increments, ⌘0 to reset. Doesn't affect the lock screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Three-element live sample — same colour applied as icon tint, as
    /// border+foreground, and as fill — so the user can see at a glance
    /// how the chosen theme reads across the typical roles SwiftUI's
    /// `.tint` ends up in (text accents, outlined controls, filled buttons).
    /// Animated together with the chip selection.
    private var themePreview: some View {
        let c = settings.appTheme.color
        return HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(c)

            Text("Aa")
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(c)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(c, lineWidth: 1.2)
                )

            Text("Action")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(c))
        }
        .animation(.easeInOut(duration: 0.25), value: settings.appTheme)
    }

    private func themeChip(_ theme: AppTheme) -> some View {
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
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .shadow(radius: 1)
                    } else {
                        Image(systemName: theme.icon)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .frame(width: 36, height: 36)
                .scaleEffect(selected ? 1.08 : 1.0)

                Text(theme.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .help(theme.label)
    }

    private var knowledgeSection: some View {
        tintedSection("Codeword knowledge") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show on launcher and lock screen", isOn: $settings.showCodewordKnowledge)
                Text("Curated geology summary plus 10 facts per codeword. Hover the ghost icons on the launcher, or read them rotating in the lock screen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Tint codeword in theme color as you type it", isOn: $settings.showCodewordProgress)
                Text("Off skips a per-wipe HUD redraw — turn off if you hear sound stutter under sustained typing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cleanmapSection: some View {
        tintedSection("Cleanmap") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accumulated wipe data")
                        .font(.body)
                    Text("\(controller.overallKeyCounts.values.reduce(0, +)) overall · \(controller.sessionKeyCounts.values.reduce(0, +)) this session · \(controller.overallKeyCounts.count) keys")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showCleanmap = true
                } label: {
                    Label("View", systemImage: "chart.bar.fill")
                }
                .buttonStyle(.bordered)
                .disabled(controller.overallKeyCounts.isEmpty && controller.sessionKeyCounts.isEmpty)
            }
        }
    }

    private var historySection: some View {
        tintedSection("Cleaning history") {
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
        tintedSection("Auto-unlock") {
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
        tintedSection("About") {
            // Header line: icon + name/version + GitHub-link inline.
            HStack(spacing: 12) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(settings.appTheme.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text("KeebLock").font(.headline)
                    Text("Version \(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: URL(string: "https://github.com/bmmmm") ?? URL(fileURLWithPath: "/")) {
                    Label("@bmmmm", systemImage: "person.circle")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }

            Text("Swallows keystrokes via macOS Accessibility while you wipe down your keys. Type the codeword (suffix-match) to escape — or click the unlock icon once you're half-way through.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Ko-fi support
            Link(destination: URL(string: "https://ko-fi.com/bmabma?utm_source=keeblock&utm_medium=desktop_app") ?? URL(fileURLWithPath: "/")) {
                HStack(spacing: 8) {
                    Image(systemName: "cup.and.saucer.fill")
                        .foregroundStyle(.pink)
                    Text("Support development on Ko-fi")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)

            // Credits + uninstall folded into a disclosure so the section
            // doesn't dominate the form for the 95 % of opens that don't
            // need them.
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("Summaries & facts:")
                            .foregroundStyle(.secondary)
                        Link("Wikipedia", destination: URL(string: "https://en.wikipedia.org") ?? URL(fileURLWithPath: "/"))
                    }
                    HStack(spacing: 4) {
                        Text("Lead images:")
                            .foregroundStyle(.secondary)
                        Link("Wikimedia Commons", destination: URL(string: "https://commons.wikimedia.org") ?? URL(fileURLWithPath: "/"))
                        Text("(CC-BY-SA)")
                            .foregroundStyle(.secondary)
                    }
                    Divider().padding(.vertical, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .foregroundStyle(.secondary)
                            Text("Uninstall — run either:")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(uninstallCommands, id: \.self) { cmd in
                            HStack(spacing: 6) {
                                Text(cmd)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(cmd, forType: .string)
                                    copiedCommand = cmd
                                    Task { @MainActor in
                                        try? await Task.sleep(for: .milliseconds(1500))
                                        if copiedCommand == cmd { copiedCommand = nil }
                                    }
                                } label: {
                                    Image(systemName: copiedCommand == cmd ? "checkmark.circle.fill" : "doc.on.doc")
                                        .foregroundStyle(copiedCommand == cmd ? .green : .secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Copy to clipboard")
                            }
                        }
                    }
                }
                .font(.caption)
                .padding(.top, 4)
            } label: {
                Text("Credits & uninstall")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appVersion: String { Bundle.main.keeblockVersionString }

    /// Slider label: dB scale because amplitude perception is logarithmic.
    /// 100 % = 0 dB (full output), 50 % ≈ −6 dB, 10 % ≈ −20 dB,
    /// 200 % ≈ +6 dB (overdrive). 0 % shows −∞ to make it obvious the
    /// click is silent rather than just quiet. Positive values are
    /// signed to make the overdrive zone unambiguous.
    private var volumeLabel: String {
        if settings.soundVolume <= 0.001 { return "−∞ dB" }
        let db = 20 * log10(settings.soundVolume)
        return String(format: "%+.0f dB", db)
    }

    private var debugSection: some View {
        tintedSection("Debug") {
            Toggle("Enable debug logging", isOn: $settings.debugLoggingEnabled)

            if settings.debugLoggingEnabled {
                Toggle("Verbose perf sampling (callback latency, p99)", isOn: $settings.verbosePerfEnabled)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Lock-screen overlay")
                        .font(.callout)
                    Picker("Lock-screen overlay", selection: $settings.lockOverlayDebugLevel) {
                        ForEach(LockOverlayDebugLevel.allCases) { lvl in
                            Text(lvl.label).tag(lvl)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Border-strip HUD around the lock window. Higher levels add more rows AND dampen the spark/effect intensity so the readout stays readable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Snapshot includes screen layout, lock state, the name of your frontmost app, and recent keycodes (as numbers, not characters). Review before sharing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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

                    Button("Open log folder") {
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

                HStack {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text("Max log file size")
                    Spacer()
                    Stepper(value: $settings.logFileMaxSizeMB, in: 1...100) {
                        Text("\(settings.logFileMaxSizeMB) MB")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                Text("When the log exceeds this, it rotates: current file becomes keeblock.log.old (replacing any previous backup) and a fresh keeblock.log starts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DebugInfoPanel(settings: settings, controller: controller)
                    .padding(.top, 8)
                    .id(Self.debugBottomID)
            }
        }
    }

    // MARK: - Actions

    private func pickSoundFile() {
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

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
