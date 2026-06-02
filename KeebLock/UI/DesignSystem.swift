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
