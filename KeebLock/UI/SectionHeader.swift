import SwiftUI

/// All-caps section eyebrow — "DID YOU KNOW?", "KEYBOARD", "14-DAY ACTIVITY".
/// Was four near-identical hand-rolled specs across the HUD and history views
/// (different sizes, weights, tracking, casing); this is the single source.
/// Bundles `Font.sectionEyebrow` with the tracking and uppercasing those labels
/// shared. `color` defaults to the muted ladder for the dark HUD; pass `.tint`
/// or a status color where the context differs.
///
/// Note: the Settings Form already has a disciplined header via
/// `tintedSection`; this eyebrow is for the HUD / launcher / history panels.
struct SectionEyebrow: View {
    private let text: String
    private let color: Color

    init(_ text: String, color: Color = .mutedSubtle) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.sectionEyebrow)
            .tracking(2)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}
