/// Pure keystroke classification: static lookup tables plus side-effect-free
/// functions that turn a raw `(keycode, produced characters)` pair into a
/// bucket and normalise codeword input across keyboard layouts. Deliberately
/// free of any singleton access (`AppSettings`, `PerfMetrics`, window manager)
/// so it can be unit-tested exhaustively and stays trivially reasoned about on
/// the main-thread hot path. All tables are `static let` — no per-keystroke
/// allocation.
enum KeyClassifier {
    /// Which counter bucket a physical key event falls into. `.media` is not
    /// produced by `classify(keycode:chars:)`; it is assigned directly by the
    /// NX_SYSDEFINED media-key path in the event tap.
    enum KeyBucket {
        case function, control, letter, number, symbol, media
    }

    static let functionKeycodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90,                     // F13–F20 (extended Apple keyboards)
    ]

    /// Non-printable navigation / editing / whitespace keys. Distinguished
    /// from `symbolCount` so the breakdown shows e.g. heavy Backspace usage
    /// separately from punctuation.
    static let controlKeycodes: Set<UInt16> = [
        36,   // Return
        48,   // Tab
        49,   // Space
        51,   // Delete (Backspace)
        53,   // Escape
        76,   // Enter (Numpad)
        114,  // Help / Insert
        115,  // Home
        116,  // Page Up
        117,  // Forward Delete
        119,  // End
        121,  // Page Down
        123,  // Left Arrow
        124,  // Right Arrow
        125,  // Down Arrow
        126,  // Up Arrow
    ]

    /// NX_KEYTYPE → F-key keycode. macOS fires media/brightness keys as
    /// system-defined events with NX_KEYTYPE codes (independent of regular
    /// keyboard keycodes). Mapping them to the F-key the user actually pressed
    /// lets the cleanmap show "F1 was hit 12 times" regardless of fnState.
    static let nxToFnKeycode: [Int: UInt16] = [
        0:  111, // SOUND_UP        → F12
        1:  103, // SOUND_DOWN      → F11
        2:  120, // BRIGHTNESS_UP   → F2
        3:  122, // BRIGHTNESS_DOWN → F1
        7:  109, // MUTE            → F10
        16: 100, // PLAY            → F8
        17: 101, // NEXT            → F9
        18: 98,  // PREVIOUS        → F7
        // Modern Apple Magic Keyboards emit FAST/REWIND for the same
        // physical F-keys older keyboards report as NEXT/PREVIOUS.
        // Map them to the same F-keys so the wipe lands in the same
        // place regardless of which hardware generation is in use.
        19: 101, // FAST            → F9
        20: 98,  // REWIND          → F7
    ]

    /// Sentinel keycode for NX_SYSDEFINED media/system keys with no F-key
    /// projection (Mission Control, Launchpad, Dictation, Do-Not-Disturb, …).
    /// Real hardware keycodes top out at 126 (KeyboardLayout) / 179
    /// (KeyboardPositionMap's alias table), so `.max` can't collide with an
    /// actual physical key when it lands in sessionKeyCounts/overallKeyCounts/
    /// sessionTrail — KeyboardPositionMap.mapping(for:) safely returns nil for
    /// it, and every consumer already treats nil as "no visual position"
    /// (skipped, not a crash).
    static let unmappedMediaKeycode: UInt16 = .max

    /// Hard-coded US-ANSI keycode → ASCII character map. Used as a fallback
    /// when the active keyboard layout produces non-ASCII characters
    /// (Greek, Cyrillic, Arabic, Hebrew, …) — without it those users would
    /// type the codeword by physical key position but feed the matcher
    /// non-Latin glyphs that never match. With this fallback the V key is
    /// always V for matching purposes regardless of layout. Only covers the
    /// alphanumeric range needed for codewords.
    static let usLayoutMap: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k",
        45: "n", 46: "m",
    ]

    /// Bucket a regular `keyDown` event. Order matters: F-keys and control
    /// keys are checked first because they have keycodes but their printable
    /// chars can be misleading (e.g. arrow keys produce private-use codepoints
    /// that pass `isLetter` on some layouts). Never returns `.media`.
    static func classify(keycode: UInt16, chars: String) -> KeyBucket {
        if functionKeycodes.contains(keycode) {
            return .function
        } else if controlKeycodes.contains(keycode) {
            return .control
        } else if let first = chars.first, first.isLetter {
            return .letter
        } else if let first = chars.first, first.isNumber {
            return .number
        } else {
            // Punctuation and printable symbols that are neither letter nor
            // number: , . ; : ' " ! @ # $ % & * ( ) - _ = + [ ] { } etc.
            return .symbol
        }
    }

    /// Normalise a produced character for codeword matching. ASCII passes
    /// through unchanged; a non-ASCII glyph (Greek/Cyrillic/etc.) falls back
    /// to the US-layout character for its physical key position so the user
    /// can still type the codeword by position, or stays unchanged if the
    /// keycode has no US-layout entry.
    static func normalizedForMatching(character: Character, keycode: UInt16) -> Character {
        character.isASCII ? character : (usLayoutMap[keycode] ?? character)
    }
}
