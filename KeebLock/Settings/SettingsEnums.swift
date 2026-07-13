import simd
import SwiftUI

// MARK: - Screen effect type

enum ScreenEffect: String, CaseIterable, Identifiable, Codable {
    case sparks, rain, matrix, bubbles, snow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sparks:  return "Sparks"
        case .rain:    return "Rain"
        case .matrix:  return "Matrix"
        case .bubbles: return "Bubbles"
        case .snow:    return "Snow"
        }
    }

    var icon: String {
        switch self {
        case .sparks:  return "sparkles"
        case .rain:    return "cloud.rain.fill"
        case .matrix:  return "chevron.down.square.fill"
        case .bubbles: return "bubbles.and.sparkles"
        case .snow:    return "snowflake"
        }
    }

    var activeColor: Color {
        switch self {
        case .sparks:  return Color(red: 0.73, green: 0.60, blue: 0.98)
        case .rain:    return Color(red: 0.25, green: 0.55, blue: 0.95)
        case .matrix:  return Color(red: 0.05, green: 0.75, blue: 0.25)
        case .bubbles: return Color(red: 0.30, green: 0.80, blue: 1.00)
        case .snow:    return Color(red: 0.60, green: 0.80, blue: 1.00)
        }
    }

    var sliderLeftIcon: String {
        switch self {
        case .sparks:  return "sparkle"
        case .rain:    return "drop"
        case .matrix:  return "character"
        case .bubbles: return "circle"
        case .snow:    return "wind.snow"
        }
    }

    var sliderRightIcon: String {
        switch self {
        case .sparks:  return "sparkles"
        case .rain:    return "cloud.rain.fill"
        case .matrix:  return "chevron.down.square.fill"
        case .bubbles: return "bubbles.and.sparkles.fill"
        case .snow:    return "snowflake"
        }
    }

    var intensityDescription: String {
        switch self {
        case .sparks:  return "Particles per wipe"
        case .rain:    return "Drops per wipe"
        case .matrix:  return "Characters per wipe"
        case .bubbles: return "Bubbles per wipe"
        case .snow:    return "Flakes per wipe"
        }
    }
}

// MARK: - Wipe mode

/// How keystrokes choose which mask cell gets cleared.
///
/// `.random` keeps the original behaviour: every press wipes a random
/// remaining cell, so the screen reveals uniformly. `.positional` maps
/// the physical keycode to the equivalent on-screen position via
/// `KeyboardPositionMap` — pressing Q clears the upper-left corner,
/// pressing space clears the bottom centre. Lets the user "scrub" the
/// screen clean by physically navigating their keyboard.
enum WipeMode: String, CaseIterable, Identifiable, Codable {
    case random, positional

    var id: String { rawValue }

    var label: String {
        switch self {
        case .random:     return "Random"
        case .positional: return "Positional"
        }
    }

    var icon: String {
        switch self {
        case .random:     return "shuffle"
        case .positional: return "keyboard"
        }
    }

    /// Tint used by the launcher's WipeModeToggle card. Both modes are
    /// always-on (there is no "off" wipe mode), so we just pick two
    /// distinct hues so the active card colour changes when the user
    /// flips between them.
    var activeColor: Color {
        switch self {
        case .random:     return Color(red: 0.55, green: 0.65, blue: 0.98)
        case .positional: return Color(red: 0.45, green: 0.82, blue: 0.62)
        }
    }

    var helpText: String {
        switch self {
        case .random:     return "Each wipe clears a random cell — the screen reveals uniformly."
        case .positional: return "Each wipe clears the cell under the key you pressed — type to scrub specific areas."
        }
    }
}

// MARK: - Lock-screen debug overlay level

/// Border-strip live-debug HUD shown around the lock screen, off by default.
/// Higher levels show more rows AND tone down lock-screen animations so the
/// overlay's text stays legible (per the user request to "reduce
/// animations" when the overlay is on).
enum LockOverlayDebugLevel: String, CaseIterable, Identifiable, Codable, Comparable {
    case off, minimal, standard, verbose

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off:      return "Off"
        case .minimal:  return "Minimal"
        case .standard: return "Standard"
        case .verbose:  return "Verbose"
        }
    }

    private var ordinal: Int {
        switch self {
        case .off: return 0
        case .minimal: return 1
        case .standard: return 2
        case .verbose: return 3
        }
    }

    static func < (lhs: LockOverlayDebugLevel, rhs: LockOverlayDebugLevel) -> Bool {
        lhs.ordinal < rhs.ordinal
    }
}

// MARK: - Color presets

/// Predefined color choices for both the background and the cleaning pixel layers.
/// `.random` = renderer picks a fresh hue per stage. `.transparent` = alpha 0
/// (desktop visible). All other cases are opaque pastel presets.
enum ColorPreset: String, CaseIterable, Identifiable, Codable {
    case random
    case transparent
    case rose
    case lavender
    case mint
    case sky
    case peach
    case lemon
    case coral
    case lilac

    var id: String { rawValue }
    var label: String {
        switch self {
        case .random: return "Random"
        case .transparent: return "Transparent"
        default: return rawValue.capitalized
        }
    }

    /// nil = let renderer roll a random color per stage.
    var rgba: [Double]? {
        switch self {
        case .random:      return nil
        case .transparent: return [0, 0, 0, 0]
        case .rose:        return [1.00, 0.71, 0.76, 1.0]
        case .lavender:    return [0.73, 0.60, 0.98, 1.0]
        case .mint:        return [0.62, 0.96, 0.78, 1.0]
        case .sky:         return [0.60, 0.85, 1.00, 1.0]
        case .peach:       return [1.00, 0.78, 0.60, 1.0]
        case .lemon:       return [1.00, 0.96, 0.52, 1.0]
        case .coral:       return [1.00, 0.60, 0.60, 1.0]
        case .lilac:       return [0.82, 0.65, 1.00, 1.0]
        }
    }

    var simd: SIMD4<Float>? {
        guard let c = rgba else { return nil }
        return SIMD4<Float>(Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
    }

    var swiftUIColor: Color {
        guard let c = rgba else { return .accentColor }   // placeholder for .random
        return Color(red: c[0], green: c[1], blue: c[2]).opacity(c[3])
    }
}

// MARK: - App theme (global accent)

/// Tints the entire app — applied as `.tint(...)` on the root WindowGroup.
/// Each case maps to a named color set in Assets.xcassets that carries its
/// own Light/Dark variants, so the appearance follows the system mode while
/// staying within the chosen palette family.
enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case day, dark, sakura, coffee, bath

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day:    return "Day"
        case .dark:   return "Sleepy"
        case .sakura: return "Sakura"
        case .coffee: return "Coffee"
        case .bath:   return "Bath"
        }
    }

    var icon: String {
        switch self {
        case .day:    return "sun.max.fill"
        case .dark:   return "moon.fill"
        case .sakura: return "leaf.fill"
        case .coffee: return "cup.and.saucer.fill"
        case .bath:   return "drop.fill"
        }
    }

    /// Asset Catalog color-set name. AccentColor is the project default and
    /// carries the Day palette so SwiftUI's implicit `Color.accentColor`
    /// references stay sensible when the user hasn't picked a theme yet.
    var accentColorName: String {
        switch self {
        case .day:    return "AccentColor"
        case .dark:   return "AccentDark"
        case .sakura: return "AccentSakura"
        case .coffee: return "AccentCoffee"
        case .bath:   return "AccentBath"
        }
    }

    var color: Color { Color(accentColorName) }
}
