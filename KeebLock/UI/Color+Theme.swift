import SwiftUI

// Semantic color layer. The app expressed the same intents with three parallel
// systems: SwiftUI semantics (.tint / .secondary), the themed
// AppSettings.appTheme.color, and raw literals. In particular the HUD spelled
// "card background" with several black-opacity values and "muted text" with
// ~half a dozen white-opacity values, all by eye. These names fold those
// ladders down so the depth hierarchy is intentional and consistent.
//
// Accent: prefer the `.tint` ShapeStyle (e.g. `.foregroundStyle(.tint)`,
// `.fill(.tint.opacity(0.08))`). The root WindowGroup sets
// `.tint(appTheme.color)`, so `.tint` already carries the active theme — leaf
// views should read it from the environment instead of reaching into
// AppSettings.shared.appTheme.color. Genuine *status* colors (.red / .orange /
// .green build-shield, overdrive warning) and per-effect activeColors stay
// literal: they encode meaning, not theme.
extension Color {
    // MARK: Launcher / settings surfaces (light-mode-aware, built on .primary)

    /// Whisper-faint fill (zebra rows, inset wells).
    static let surfaceFaint = Color.primary.opacity(0.03)
    /// Default subtle surface fill — inactive launcher chips, card backings.
    static let surfaceSubtle = Color.primary.opacity(0.06)
    /// Hairline strokes / dividers.
    static let hairline = Color.primary.opacity(0.10)

    // MARK: HUD scrims & cards (drawn over the wipe canvas, built on black)

    /// Light scrim that lifts text off the canvas without hiding it.
    static let hudScrim = Color.black.opacity(0.25)
    /// Standard HUD card background.
    static let hudCard = Color.black.opacity(0.35)
    /// Opaque-ish HUD panel (knowledge card, debug strip).
    static let hudPanel = Color.black.opacity(0.82)

    // MARK: Muted foreground ladder (over the dark HUD, built on white)

    /// Primary muted text — high-contrast secondary content.
    static let mutedStrong = Color.white.opacity(0.85)
    /// Standard muted text.
    static let muted = Color.white.opacity(0.70)
    /// Quieter muted text — captions, hints.
    static let mutedSubtle = Color.white.opacity(0.55)
    /// Faintest muted text — disabled / placeholder.
    static let mutedFaint = Color.white.opacity(0.45)
}

extension LinearGradient {
    /// Five-stop spectrum that represents the "random color" preset. Was
    /// copy-pasted at four call sites (HUD codeword swatch, the launcher color
    /// chip, its picker, and the Settings color picker).
    static let presetRainbow = LinearGradient(
        colors: [.pink, .yellow, .green, .blue, .purple],
        startPoint: .leading, endPoint: .trailing
    )
}
