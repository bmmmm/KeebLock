import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var controller: LockController
    @ObservedObject var history: CleaningHistory = .shared

    /// Same window-width scale that drives the launcher. The grouped Form's
    /// native AppKit controls only respond to dynamic type, so the continuous
    /// scale is bucketed onto the `DynamicTypeSize` ladder below; explicit
    /// font sizes (the codeword display) multiply by it directly.
    @Environment(\.uiScale) private var uiScale

    @State private var suggestions: [String] = Codewords.suggestions()
    @State private var showCleanmap = false
    @State private var showTrailmap = false
    @State private var showHistory = false
    @State private var snapshotMessage: String?
    @State private var snapshotMessageToken = 0
    @State private var copiedCommand: String?
    @State private var codewordEditing = false
    @State private var codewordBeforeEdit = ""
    @FocusState private var codewordFocused: Bool

    // MARK: - Scaled fonts
    //
    // Settings drives its type the same way the launcher does: explicit point
    // sizes multiplied by `uiScale`, not the `DynamicTypeSize` ladder. macOS
    // under-amplifies dynamic type, so that ladder left the form reading small
    // next to the launcher however high it was set. These helpers keep the
    // call sites terse — the argument is the role's base size at uiScale 1.0,
    // tuned to read as large as the launcher's body text.
    private func scaled(_ size: CGFloat, _ weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        .system(size: size * uiScale, weight: weight, design: mono ? .monospaced : .default)
    }

    private var fCaption2: Font { scaled(13) }
    private var fCaption: Font  { scaled(14) }
    private var fCallout: Font  { scaled(16) }
    private var fBody: Font     { scaled(17) }

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
                trailmapSection
                historySection
                autoUnlockSection
                aboutSection
                debugSection
            }
            .formStyle(.grouped)
            // Base font for the native control labels (Toggle / Picker /
            // Stepper text) that aren't individually styled below — they
            // inherit the environment font, so this scales them with the
            // window. `dynamicTypeSize` stays as a secondary nudge for any
            // control chrome that only honours dynamic type.
            .font(scaled(16))
            .dynamicTypeSize(UIScale.dynamicType(for: uiScale))
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
            .sheet(isPresented: $showTrailmap) {
                TrailmapView(controller: controller)
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
                    TextField("codeword", text: Binding(
                        get: { settings.codeword },
                        set: {
                            let cleaned = sanitizeCodewordInput($0)
                            // Only write back on an actual change so a rejected
                            // character (filtered to a no-op) doesn't churn the
                            // didSet / UserDefaults write on every keystroke.
                            if cleaned != settings.codeword { settings.codeword = cleaned }
                        }
                    ))
                        .font(.system(size: 22 * uiScale, weight: .semibold, design: .monospaced))
                        .tracking(2 * uiScale)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.plain)
                        .focused($codewordFocused)
                        .onSubmit { commitCodeword() }
                        .onChange(of: codewordFocused) { _, focused in
                            if !focused { commitCodeword() }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.md)
                                .fill(settings.appTheme.color.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.md)
                                        .strokeBorder(settings.appTheme.color, lineWidth: 1.5)
                                )
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                } else {
                    Button {
                        codewordBeforeEdit = settings.codeword
                        withAnimation(.spring(response: 0.3)) { codewordEditing = true }
                        codewordFocused = true
                    } label: {
                        HStack(spacing: 12) {
                            Text(settings.codeword.uppercased())
                                .font(.system(size: 22 * uiScale, weight: .semibold, design: .monospaced))
                                .tracking(2 * uiScale)
                                .foregroundStyle(.primary)
                            Image(systemName: "pencil")
                                .font(fCaption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.md)
                                .fill(Color.primary.opacity(0.05))
                                .overlay(
                                    RoundedRectangle(cornerRadius: Radius.md)
                                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: codewordEditing)

            if codewordEditing {
                Text("Letters and numbers only")
                    .font(fCaption2)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            HStack {
                Text("Suggestions — geology")
                    .font(fCaption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.35)) {
                        suggestions = Codewords.suggestions()
                    }
                } label: {
                    Label("Roll new", systemImage: "arrow.triangle.2.circlepath")
                        .font(scaled(14, .medium))
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
                            .font(scaled(16, mono: true))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                settings.codeword == word
                                ? RoundedRectangle(cornerRadius: Radius.sm).fill(settings.appTheme.color.opacity(0.15))
                                : RoundedRectangle(cornerRadius: Radius.sm).fill(Color.primary.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Radius.sm)
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

    /// Strip anything the keystroke matcher can't receive — it is only ever fed
    /// ASCII letters and digits (non-ASCII input is remapped to its US-layout
    /// ASCII key) — so a stored codeword can never contain a character that makes
    /// it impossible to type during a lock. Case is preserved; matching is
    /// case-insensitive.
    private func sanitizeCodewordInput(_ raw: String) -> String {
        String(raw.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// End codeword editing (Return or focus loss). An empty field would arm an
    /// unmatchable lock, so restore the value the user started editing from rather
    /// than persist "" — clearing and bailing out reads as "cancel", not "surprise
    /// me with a random word". Fall back to a fresh suggestion only if the pre-edit
    /// value was itself empty (shouldn't happen — the lock can't arm empty).
    private func commitCodeword() {
        if settings.codeword.isEmpty {
            settings.codeword = codewordBeforeEdit.isEmpty ? Codewords.random() : codewordBeforeEdit
        }
        withAnimation(.spring(response: 0.3)) { codewordEditing = false }
    }

    private var pixelSection: some View {
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

    private var wipeModeSection: some View {
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

    private var colorsSection: some View {
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

    private func colorRow(label: String, binding: Binding<ColorPreset>) -> some View {
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

    private func presetSwatch(_ preset: ColorPreset, isSelected: Bool, action: @escaping () -> Void) -> some View {
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
    private func presetSwatchFill(_ preset: ColorPreset) -> some View {
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
    private var themePreview: some View {
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

    private var knowledgeSection: some View {
        tintedSection("Codeword knowledge") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Show on launcher and lock screen", isOn: $settings.showCodewordKnowledge)
                Text("Curated geology summary plus hand-picked facts per codeword. Hover the ghost icons on the launcher, or read the did-you-know snippets rotating in the lock screen.")
                    .font(fCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Tint codeword in theme color as you type it", isOn: $settings.showCodewordProgress)
                Text("Off skips a per-wipe HUD redraw — turn off if you hear sound stutter under sustained typing.")
                    .font(fCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var cleanmapSection: some View {
        tintedSection("Cleanmap") {
            // The count stores are @ObservationIgnored — subscribe to the
            // reset pulse so a Reset inside the sheet refreshes this row too.
            let _ = controller.statsResetPulse
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Accumulated wipe data")
                        .font(fBody)
                    Text("\(controller.overallKeyCounts.values.reduce(0, +)) overall · \(controller.sessionKeyCounts.values.reduce(0, +)) this session · \(controller.overallKeyCounts.count) keys")
                        .font(fCaption)
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

    private var trailmapSection: some View {
        tintedSection("Trailmap") {
            // Same rationale as cleanmapSection: sessionTrail is
            // @ObservationIgnored, the pulse carries the reset signal.
            let _ = controller.statsResetPulse
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wipe trail visualisation")
                        .font(fBody)
                    Text("\(controller.sessionTrail.count) wipes this session")
                        .font(fCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showTrailmap = true
                } label: {
                    Label("View", systemImage: "scribble.variable")
                }
                .buttonStyle(.bordered)
                .disabled(controller.sessionTrail.isEmpty)
            }
        }
    }

    private var historySection: some View {
        tintedSection("Cleaning history") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Past sessions")
                        .font(fBody)
                    if let last = history.lastWipe {
                        Text("Last wipe: \(formatDate(last))")
                            .font(fCaption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No sessions recorded yet")
                            .font(fCaption)
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
                .font(fCaption)
                .foregroundStyle(.secondary)
        }
    }

    private var aboutSection: some View {
        tintedSection("About") {
            // Header line: icon + name/version + GitHub-link inline.
            HStack(spacing: 12) {
                Image(systemName: "keyboard.fill")
                    .font(.system(size: 22 * uiScale))
                    .foregroundStyle(settings.appTheme.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text("KeebLock").font(scaled(20, .semibold))
                    Text("Version \(appVersion)")
                        .font(fCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link(destination: URL(string: "https://github.com/bmmmm") ?? URL(fileURLWithPath: "/")) {
                    Label("@bmmmm", systemImage: "person.circle")
                        .font(fCallout)
                }
                .buttonStyle(.borderless)
            }

            Text("Swallows keystrokes via macOS Accessibility while you wipe down your keys. Type the codeword (suffix-match) to escape — or click the unlock icon once you're half-way through.")
                .font(fCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Ko-fi support
            Link(destination: URL(string: "https://ko-fi.com/bmabma?utm_source=keeblock&utm_medium=desktop_app") ?? URL(fileURLWithPath: "/")) {
                HStack(spacing: 8) {
                    Image(systemName: "cup.and.saucer.fill")
                        .foregroundStyle(.pink)
                    Text("Support development on Ko-fi")
                        .font(scaled(16, .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .font(fCaption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.pink.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.sm))
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
                                    .font(scaled(14, mono: true))
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.xs))
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
                .font(fCaption)
                .padding(.top, 4)
            } label: {
                Text("Credits & uninstall")
                    .font(scaled(14, .semibold))
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
                        .font(fCallout)
                    Picker("Lock-screen overlay", selection: $settings.lockOverlayDebugLevel) {
                        ForEach(LockOverlayDebugLevel.allCases) { lvl in
                            Text(lvl.label).tag(lvl)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text("Border-strip HUD around the lock window. Higher levels add more rows AND dampen the spark/effect intensity so the readout stays readable.")
                        .font(fCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Snapshot includes screen layout, lock state, the name of your frontmost app, and recent keycodes (as numbers, not characters). Review before sharing.")
                    .font(fCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Save snapshot") {
                        let snap = DebugLog.snapshot()
                        DebugLog.writeForced(snap)
                        showSnapshotMessage("Snapshot appended to log.")
                    }
                    .buttonStyle(.bordered)

                    Button("Copy all debug info") {
                        let snap = DebugLog.snapshot()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(snap, forType: .string)
                        showSnapshotMessage("Copied to clipboard.")
                    }
                    .buttonStyle(.bordered)

                    Button("Open log folder") {
                        DebugLog.revealLogInFinder()
                    }
                    .buttonStyle(.bordered)
                }

                if let snapshotMessage {
                    Text(snapshotMessage)
                        .font(fCaption)
                        .foregroundStyle(.green)
                }

                Text("Log path: ~/Library/Logs/KeebLock/keeblock.log")
                    .font(fCaption)
                    .foregroundStyle(.secondary)

                HStack {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text("Max log file size")
                    Spacer()
                    Stepper(value: $settings.logFileMaxSizeMB, in: 1...100) {
                        Text("\(settings.logFileMaxSizeMB) MB")
                            .font(scaled(17, mono: true))
                    }
                }
                Text("When the log exceeds this, it rotates: current file becomes keeblock.log.old (replacing any previous backup) and a fresh keeblock.log starts.")
                    .font(fCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                DebugInfoPanel(settings: settings, controller: controller)
                    .padding(.top, 8)
                    .id(Self.debugBottomID)
            }
        }
    }

    // MARK: - Actions

    /// Show a transient confirmation under the debug buttons, then auto-clear
    /// it after ~2s. Mirrors the `copiedCommand` pattern; a generation token
    /// guards against an older timer wiping a newer message.
    private func showSnapshotMessage(_ message: String) {
        snapshotMessage = message
        snapshotMessageToken += 1
        let token = snapshotMessageToken
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if snapshotMessageToken == token { snapshotMessage = nil }
        }
    }

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
