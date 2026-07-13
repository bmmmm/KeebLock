import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    var controller: LockController
    @ObservedObject var history: CleaningHistory = .shared

    /// Same window-width scale that drives the launcher. The grouped Form's
    /// native AppKit controls only respond to dynamic type, so the continuous
    /// scale is bucketed onto the `DynamicTypeSize` ladder below; explicit
    /// font sizes (the codeword display) multiply by it directly.
    @Environment(\.uiScale) var uiScale

    @State var suggestions: [String] = Codewords.suggestions()
    @State var showCleanmap = false
    @State var showTrailmap = false
    @State var showHistory = false
    @State var snapshotMessage: String?
    @State var snapshotMessageToken = 0
    @State var copiedCommand: String?
    @State var codewordEditing = false
    @State var codewordBeforeEdit = ""
    @FocusState var codewordFocused: Bool

    // MARK: - Scaled fonts
    //
    // Settings drives its type the same way the launcher does: explicit point
    // sizes multiplied by `uiScale`, not the `DynamicTypeSize` ladder. macOS
    // under-amplifies dynamic type, so that ladder left the form reading small
    // next to the launcher however high it was set. These helpers keep the
    // call sites terse — the argument is the role's base size at uiScale 1.0,
    // tuned to read as large as the launcher's body text.
    func scaled(_ size: CGFloat, _ weight: Font.Weight = .regular, mono: Bool = false) -> Font {
        .system(size: size * uiScale, weight: weight, design: mono ? .monospaced : .default)
    }

    var fCaption2: Font { scaled(13) }
    var fCaption: Font  { scaled(14) }
    var fCallout: Font  { scaled(16) }
    var fBody: Font     { scaled(17) }

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

    static let debugBottomID = "keeblock.settings.debug.bottom"

    /// Wraps SwiftUI's stock `Section(_:content:)` with a tinted header so
    /// the group title picks up the active theme accent. The Section's
    /// own grouped-form styling is otherwise untouched, so the row layout
    /// inside stays identical to the default look.
    @ViewBuilder
    func tintedSection<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        Section {
            content()
        } header: {
            Text(title).foregroundStyle(.tint)
        }
    }
}
