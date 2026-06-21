import CoreGraphics
import Foundation

/// Single tile in the visual keyboard layout. A `nil` keycode marks a
/// decorative spacer; otherwise the keycode is the hardware code emitted
/// by `CGEvent.keyboardEventKeycode` for that physical key.
struct KeyboardKey {
    let code: UInt16?
    let label: String
    let width: CGFloat
}

/// Compact ANSI-Mac keyboard layout used in two places:
///   1. `HeatmapView` renders one tile per key, tinted by press count.
///   2. `KeyboardPositionMap` derives a normalised on-screen position
///      from a keycode so the positional wipe mode can clear the cell
///      under the key the user just pressed.
///
/// Coordinates are eyeballed but produce a recognisable keyboard at a
/// glance — the goal is "pressing Q clears the upper-left of the
/// screen", not pixel-perfect Apple geometry.
enum KeyboardLayout {
    static let rows: [[KeyboardKey]] = [
        [
            KeyboardKey(code: 53,  label: "esc",  width: 1.25),
            KeyboardKey(code: 122, label: "F1",   width: 1),
            KeyboardKey(code: 120, label: "F2",   width: 1),
            KeyboardKey(code: 99,  label: "F3",   width: 1),
            KeyboardKey(code: 118, label: "F4",   width: 1),
            KeyboardKey(code: 96,  label: "F5",   width: 1),
            KeyboardKey(code: 97,  label: "F6",   width: 1),
            KeyboardKey(code: 98,  label: "F7",   width: 1),
            KeyboardKey(code: 100, label: "F8",   width: 1),
            KeyboardKey(code: 101, label: "F9",   width: 1),
            KeyboardKey(code: 109, label: "F10",  width: 1),
            KeyboardKey(code: 103, label: "F11",  width: 1),
            KeyboardKey(code: 111, label: "F12",  width: 1),
        ],
        [
            KeyboardKey(code: 50,  label: "`",    width: 1),
            KeyboardKey(code: 18,  label: "1",    width: 1),
            KeyboardKey(code: 19,  label: "2",    width: 1),
            KeyboardKey(code: 20,  label: "3",    width: 1),
            KeyboardKey(code: 21,  label: "4",    width: 1),
            KeyboardKey(code: 23,  label: "5",    width: 1),
            KeyboardKey(code: 22,  label: "6",    width: 1),
            KeyboardKey(code: 26,  label: "7",    width: 1),
            KeyboardKey(code: 28,  label: "8",    width: 1),
            KeyboardKey(code: 25,  label: "9",    width: 1),
            KeyboardKey(code: 29,  label: "0",    width: 1),
            KeyboardKey(code: 27,  label: "-",    width: 1),
            KeyboardKey(code: 24,  label: "=",    width: 1),
            KeyboardKey(code: 51,  label: "⌫",   width: 1.25),
        ],
        [
            KeyboardKey(code: 48,  label: "⇥",   width: 1.5),
            KeyboardKey(code: 12,  label: "Q",    width: 1),
            KeyboardKey(code: 13,  label: "W",    width: 1),
            KeyboardKey(code: 14,  label: "E",    width: 1),
            KeyboardKey(code: 15,  label: "R",    width: 1),
            KeyboardKey(code: 17,  label: "T",    width: 1),
            KeyboardKey(code: 16,  label: "Y",    width: 1),
            KeyboardKey(code: 32,  label: "U",    width: 1),
            KeyboardKey(code: 34,  label: "I",    width: 1),
            KeyboardKey(code: 31,  label: "O",    width: 1),
            KeyboardKey(code: 35,  label: "P",    width: 1),
            KeyboardKey(code: 33,  label: "[",    width: 1),
            KeyboardKey(code: 30,  label: "]",    width: 1),
            KeyboardKey(code: 42,  label: "\\",   width: 1),
        ],
        [
            KeyboardKey(code: 57,  label: "⇪",   width: 1.75),
            KeyboardKey(code: 0,   label: "A",    width: 1),
            KeyboardKey(code: 1,   label: "S",    width: 1),
            KeyboardKey(code: 2,   label: "D",    width: 1),
            KeyboardKey(code: 3,   label: "F",    width: 1),
            KeyboardKey(code: 5,   label: "G",    width: 1),
            KeyboardKey(code: 4,   label: "H",    width: 1),
            KeyboardKey(code: 38,  label: "J",    width: 1),
            KeyboardKey(code: 40,  label: "K",    width: 1),
            KeyboardKey(code: 37,  label: "L",    width: 1),
            KeyboardKey(code: 41,  label: ";",    width: 1),
            KeyboardKey(code: 39,  label: "'",    width: 1),
            KeyboardKey(code: 36,  label: "↩",   width: 1.75),
        ],
        [
            KeyboardKey(code: 56,  label: "⇧",   width: 2.25),
            KeyboardKey(code: 6,   label: "Z",    width: 1),
            KeyboardKey(code: 7,   label: "X",    width: 1),
            KeyboardKey(code: 8,   label: "C",    width: 1),
            KeyboardKey(code: 9,   label: "V",    width: 1),
            KeyboardKey(code: 11,  label: "B",    width: 1),
            KeyboardKey(code: 45,  label: "N",    width: 1),
            KeyboardKey(code: 46,  label: "M",    width: 1),
            KeyboardKey(code: 43,  label: ",",    width: 1),
            KeyboardKey(code: 47,  label: ".",    width: 1),
            KeyboardKey(code: 44,  label: "/",    width: 1),
            KeyboardKey(code: 60,  label: "⇧",   width: 2),
        ],
        [
            KeyboardKey(code: 63,  label: "fn",   width: 1),
            KeyboardKey(code: 59,  label: "⌃",   width: 1),
            KeyboardKey(code: 58,  label: "⌥",   width: 1),
            KeyboardKey(code: 55,  label: "⌘",   width: 1.25),
            KeyboardKey(code: 49,  label: "space", width: 5),
            KeyboardKey(code: 54,  label: "⌘",   width: 1.25),
            KeyboardKey(code: 61,  label: "⌥",   width: 1),
            KeyboardKey(code: 123, label: "◀",   width: 1),
            KeyboardKey(code: 126, label: "▲",   width: 1),
            KeyboardKey(code: 125, label: "▼",   width: 1),
            KeyboardKey(code: 124, label: "▶",   width: 1),
        ],
    ]
}

/// Layout-derived data about a single physical key, used by the
/// positional wipe mode to place and scale the wipe.
struct KeyMapping {
    /// Centre of the key on the normalised keyboard. x ∈ [0,1]
    /// left→right, y ∈ [0,1] top→bottom.
    let position: CGPoint
    /// Width relative to a standard alphanumeric key (1.0). Drives
    /// the wipe-cell count: spacebar (5.0) clears five times the
    /// area of Q (1.0) so big keys actually feel big.
    let widthUnits: Double
    /// Normalised bounding rectangle of the key on the keyboard.
    /// Wipes for this keycode only ever land inside this rect — once
    /// every cell inside is wiped, repeating the same key has no
    /// further effect. Prevents the spam-spreads-cleaning bug where
    /// hammering one key would slowly clear the whole screen.
    let bounds: CGRect
}

/// Maps a hardware keycode to layout data so the positional wipe
/// mode can target the cell that visually corresponds to where the
/// key sits on the keyboard, and scale the cleared area to the
/// key's physical size.
///
/// Output coordinates: x ∈ [0,1] left→right, y ∈ [0,1] top→bottom.
/// Each row is normalised by its own total width — rows have slightly
/// different unit widths (modifier row is wider because of the long
/// space bar) but a real keyboard fills the same physical width edge
/// to edge, so per-row normalisation produces the visually expected
/// alignment between Q, A, Z within a column.
///
/// Keycodes outside the layout (numpad-only keys, exotic hardware)
/// return nil — the wipe is then skipped entirely (no random
/// fallback) so unmapped strokes don't pollute the cleanup pattern.
enum KeyboardPositionMap {
    /// A single key's normalised geometry on the keyboard. The edges
    /// (`xMin/xMax/yMin/yMax`) are the raw per-row-normalised values in
    /// [0,1], x left→right and y top→bottom; `bounds` is the same rect
    /// pre-assembled for callers that want a `CGRect`. `rowIndex`/`rowCount`
    /// are exposed so a caller can reproduce the row-band arithmetic
    /// (`rowIndex * height/rowCount`) bit-for-bit rather than scaling the
    /// normalised y edges, which rounds differently.
    struct LayoutRect {
        let key: KeyboardKey
        let xMin: CGFloat
        let xMax: CGFloat
        let yMin: CGFloat
        let yMax: CGFloat
        let rowIndex: Int
        let rowCount: Int

        var bounds: CGRect {
            CGRect(x: xMin, y: yMin, width: xMax - xMin, height: yMax - yMin)
        }
    }

    /// Walks every key in the layout once, computing each key's normalised
    /// bounding edges (per-row width normalisation, rows stacked top→bottom).
    /// This is the single source of truth for the keyboard coordinate maths —
    /// callers scale the normalised edges into their own coordinate space.
    /// Rows with zero total width are skipped.
    static func forEachKey(_ body: (LayoutRect) -> Void) {
        let rowCount = KeyboardLayout.rows.count
        guard rowCount > 0 else { return }
        for (rowIdx, row) in KeyboardLayout.rows.enumerated() {
            let totalWidth = row.reduce(CGFloat(0)) { $0 + $1.width }
            guard totalWidth > 0 else { continue }
            let yMin = CGFloat(rowIdx) / CGFloat(rowCount)
            let yMax = CGFloat(rowIdx + 1) / CGFloat(rowCount)
            var cursor: CGFloat = 0
            for key in row {
                let keyStart = cursor
                cursor += key.width
                let keyEnd = cursor
                body(LayoutRect(
                    key: key,
                    xMin: keyStart / totalWidth,
                    xMax: keyEnd / totalWidth,
                    yMin: yMin,
                    yMax: yMax,
                    rowIndex: rowIdx,
                    rowCount: rowCount
                ))
            }
        }
    }

    /// Cached lookup table built once, keyed by hardware keycode.
    private static let table: [UInt16: KeyMapping] = {
        var map: [UInt16: KeyMapping] = [:]
        forEachKey { entry in
            guard let code = entry.key.code else { return }
            let xMin = Double(entry.xMin)
            let xMax = Double(entry.xMax)
            let yMin = Double(entry.yMin)
            let yMax = Double(entry.yMax)
            map[code] = KeyMapping(
                position: CGPoint(x: (xMin + xMax) / 2.0, y: (yMin + yMax) / 2.0),
                widthUnits: Double(entry.key.width),
                bounds: CGRect(
                    x: xMin,
                    y: yMin,
                    width: xMax - xMin,
                    height: yMax - yMin
                )
            )
        }
        return map
    }()

    static func mapping(for keycode: UInt16) -> KeyMapping? {
        if let direct = table[keycode] { return direct }
        // Alias table for keycodes outside the canonical US-ANSI
        // layout. These cover ISO-only keys, the Globe key on
        // M-series MacBooks (replaces fn), and the non-standard
        // codes modern Magic Keyboards report for the F3-F5 system
        // action keys (Stage Manager / Spotlight / Dictation). All
        // best-effort observations — the Apple keyboard never
        // documents these; revise as new hardware shows up.
        if let aliased = aliasTable[keycode] { return table[aliased] }
        return nil
    }

    /// Maps keycodes that aren't in the canonical layout array to
    /// the keycode of their closest visual neighbour. The renderer
    /// then wipes inside that neighbour's bounding box.
    private static let aliasTable: [UInt16: UInt16] = [
        10:  6,    // ISO § / non-US-backslash → Z (between shift and Y on QWERTZ)
        160: 63,   // Globe / 🌐 → fn (M-series MacBooks)
        176: 99,   // Stage Manager / F3 alternative → F3
        177: 118,  // Search / Spotlight / F4 alternative → F4
        178: 96,   // Dictation / Mic / F5 alternative → F5
        179: 97,   // Focus / DND / F6 alternative → F6 (best-effort; unverified)
    ]

    /// Reverse of `aliasTable`: canonical keycode → all keycodes that alias to it.
    /// Used by the cleanmap to merge counts for non-standard keycodes into the
    /// matching layout tile (e.g. Stage Manager 176 folds into F3 99).
    private static let reverseAliasTable: [UInt16: [UInt16]] = {
        var result: [UInt16: [UInt16]] = [:]
        for (alias, canonical) in aliasTable {
            result[canonical, default: []].append(alias)
        }
        return result
    }()

    /// All non-canonical keycodes that alias to `canonicalKeycode`.
    /// Returns an empty array if none exist.
    static func aliasedKeycodes(for canonicalKeycode: UInt16) -> [UInt16] {
        reverseAliasTable[canonicalKeycode] ?? []
    }

    static func normalizedPosition(for keycode: UInt16) -> CGPoint? {
        mapping(for: keycode)?.position
    }
}
