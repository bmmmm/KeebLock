import SwiftUI

// Design tokens — a single source of truth for the radii, spacing, and type
// styles that had drifted across the launcher, HUD, and settings. Same-role
// elements used to pick these by eye (12 distinct corner radii, ~16 spacing
// values, three near-identical "eyebrow" label specs), so the app read as
// several apps stitched together. These scales fold the drift back together.
//
// Plain CGFloat constants rather than an enum-with-cases: call sites read
// `Radius.md` / `Space.sm`, and the values stay usable anywhere a CGFloat is.

/// Corner-radius scale. Fold map from the old hand-picked radii:
/// 2/3/5 → xs · 6 → sm · 10/14 → md · 20 → lg · 28 → xl. 4/8/12/16/24 map
/// straight onto xs/sm/md/lg/xl.
enum Radius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

/// Spacing scale. 4/8/12/16/24 was already the de-facto grid. `xxs = 2` keeps
/// the genuinely-tight hairline gaps; the off-grid strays (7/9/11/18/22 and the
/// odd 1/5) snap to the nearest step at the call site. 6 and 10 round up to
/// sm/md for breathing room.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

// MARK: - Type scale

extension Font {
    /// All-caps section eyebrow ("DID YOU KNOW?", "KEYBOARD", "14-DAY
    /// ACTIVITY"). Was four near-identical specs; this is the single one.
    /// Apply alongside `.tracking(2)` and `.textCase(.uppercase)` — or use the
    /// `SectionEyebrow` view, which bundles all three.
    static let sectionEyebrow = Font.system(size: 11, weight: .heavy, design: .rounded)

    /// Large hero stat number (was 28/34/38 across the HUD). Monospaced so
    /// digits don't jitter as counters tick.
    static let statLarge = Font.system(size: 34, weight: .heavy, design: .monospaced)

    /// Medium stat number (was 22 in a couple of spots).
    static let statMedium = Font.system(size: 22, weight: .semibold, design: .monospaced)
}

// MARK: - Responsive UI scale

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    /// Continuous typography scale derived from the launcher window's current
    /// width. `1.0` at `UIScale.referenceWidth`; grows as the user enlarges
    /// the window so the launcher text fills the new width and stays readable
    /// at any size. Multiply explicit `.system(size:)` literals by this; the
    /// Settings form additionally maps it onto `dynamicTypeSize`.
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

enum UIScale {
    /// Reference content size at which `uiScale == 1.0`. The launcher's base
    /// font sizes are tuned so the whole column fits exactly inside this box
    /// (including the TabView's tab bar + padding). The window keeps this
    /// width:height proportion, so the launcher scales but never needs to
    /// scroll. Ratio ≈ 0.73, the same proportion the old fixed 560×800
    /// window used, re-derived for the larger type.
    static let referenceWidth: CGFloat = 600
    static let referenceHeight: CGFloat = 820

    /// The aspect ratio the window is pinned to (width : height).
    static var aspectRatio: CGSize { CGSize(width: referenceWidth, height: referenceHeight) }

    /// Scale that makes the launcher fill the available window in BOTH
    /// dimensions without overflowing — the smaller of the width- and
    /// height-fit factors. Because the window is aspect-locked the two
    /// factors are equal in practice; the `min` is the belt-and-braces that
    /// guarantees "no scroll" even if the window is briefly off-ratio (e.g.
    /// clamped by the screen height). Clamped so it never collapses or
    /// explodes past readability.
    static func fit(in available: CGSize) -> CGFloat {
        guard available.width > 0, available.height > 0 else { return 1.0 }
        let byWidth = available.width / referenceWidth
        let byHeight = available.height / referenceHeight
        return min(2.6, max(0.85, min(byWidth, byHeight)))
    }

    /// Bucket the continuous scale onto the discrete `DynamicTypeSize` ladder
    /// for the Settings form, whose native AppKit controls only respond to
    /// dynamic type. Stepped rather than smooth, but keeps the form's stock
    /// `.body`/`.caption` text growing with the window. The baseline is
    /// deliberately offset *up* (scale 1.0 → `.xLarge`, not `.medium`) so the
    /// Settings text reads as large as the launcher at the default window
    /// size, not stock-small next to it.
    static func dynamicType(for scale: CGFloat) -> DynamicTypeSize {
        switch scale {
        case ..<0.95: return .large
        case ..<1.12: return .xLarge
        case ..<1.32: return .xxLarge
        case ..<1.60: return .xxxLarge
        default:      return .accessibility1
        }
    }
}
