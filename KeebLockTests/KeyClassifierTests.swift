import Testing
@testable import KeebLock

struct KeyClassifierTests {

    // MARK: - classify: function keys

    @Test func everyFunctionKeycodeClassifiesAsFunction() {
        // F-keys produce no printable chars via the tap; pass an empty string
        // so the letter/number fallbacks can't accidentally catch them.
        for keycode in KeyClassifier.functionKeycodes {
            #expect(KeyClassifier.classify(keycode: keycode, chars: "") == .function)
        }
    }

    // A function keycode wins even when the layout produces a letter-like
    // char for it — keycode checks come before the char checks.
    @Test func functionKeycodeTakesPrecedenceOverChars() {
        #expect(KeyClassifier.classify(keycode: 122, chars: "a") == .function)
    }

    // MARK: - classify: control keys

    @Test func everyControlKeycodeClassifiesAsControl() {
        for keycode in KeyClassifier.controlKeycodes {
            #expect(KeyClassifier.classify(keycode: keycode, chars: "") == .control)
        }
    }

    // Arrow keys (123–126) can emit private-use codepoints that pass isLetter
    // on some layouts; the control-keycode check must still win.
    @Test func arrowKeyWithLetterLikeCharStaysControl() {
        for keycode in [UInt16(123), 124, 125, 126] {
            #expect(KeyClassifier.classify(keycode: keycode, chars: "\u{F702}") == .control)
        }
    }

    // Space (49) produces a printable " " that is neither letter nor number;
    // without the control-keycode check it would fall through to .symbol.
    @Test func spaceClassifiesAsControlNotSymbol() {
        #expect(KeyClassifier.classify(keycode: 49, chars: " ") == .control)
    }

    // MARK: - classify: letters / numbers / symbols

    @Test func letterClassifiesAsLetter() {
        // 9 = "v" on US ANSI, not in the function/control tables.
        #expect(KeyClassifier.classify(keycode: 9, chars: "v") == .letter)
    }

    @Test func numberClassifiesAsNumber() {
        // 29 = "0" on US ANSI.
        #expect(KeyClassifier.classify(keycode: 29, chars: "0") == .number)
    }

    @Test func punctuationClassifiesAsSymbol() {
        // 43 = "," on US ANSI (not in any table); a comma is neither letter
        // nor number.
        for symbol in [",", ".", ";", "'", "-", "=", "[", "]", "/", "\\"] {
            #expect(KeyClassifier.classify(keycode: 43, chars: symbol) == .symbol)
        }
    }

    // No produced characters and no keycode-table hit → symbol (the final
    // else). e.g. a dead-key or an exotic keycode with empty chars.
    @Test func emptyCharsWithUnknownKeycodeClassifiesAsSymbol() {
        #expect(KeyClassifier.classify(keycode: 200, chars: "") == .symbol)
    }

    // A non-ASCII letter (Greek/Cyrillic) still counts as a letter — classify
    // uses Character.isLetter, which is Unicode-aware.
    @Test func nonASCIILetterClassifiesAsLetter() {
        #expect(KeyClassifier.classify(keycode: 9, chars: "β") == .letter)
        #expect(KeyClassifier.classify(keycode: 9, chars: "я") == .letter)
    }

    // MARK: - classify: never returns .media

    @Test func classifyNeverReturnsMedia() {
        // Sweep the whole real-hardware keycode range plus a few chars.
        for keycode in UInt16(0)...127 {
            for chars in ["", "a", "1", ",", " "] {
                #expect(KeyClassifier.classify(keycode: keycode, chars: chars) != .media)
            }
        }
    }

    // MARK: - usLayoutMap fallback (normalizedForMatching)

    @Test func asciiCharacterPassesThroughUnchanged() {
        // ASCII always wins regardless of what usLayoutMap holds for the key.
        #expect(KeyClassifier.normalizedForMatching(character: "q", keycode: 12) == "q")
        #expect(KeyClassifier.normalizedForMatching(character: "7", keycode: 26) == "7")
        // ASCII char on a keycode with no map entry: still unchanged.
        #expect(KeyClassifier.normalizedForMatching(character: "z", keycode: 200) == "z")
    }

    // Non-ASCII glyph on a mapped keycode falls back to the US-layout char for
    // that physical position — every row of usLayoutMap is a vector here.
    @Test func nonASCIIFallsBackToUSLayoutForEveryMappedKeycode() {
        for (keycode, expected) in KeyClassifier.usLayoutMap {
            // "β" is non-ASCII, so the fallback path is exercised; the keycode
            // decides the result, not the incoming glyph.
            #expect(KeyClassifier.normalizedForMatching(character: "β", keycode: keycode) == expected)
        }
    }

    // Non-ASCII glyph on an UNmapped keycode stays as-is (no US fallback).
    @Test func nonASCIIOnUnmappedKeycodeStaysUnchanged() {
        // 10 and 200 are gaps in usLayoutMap.
        #expect(KeyClassifier.normalizedForMatching(character: "β", keycode: 10) == "β")
        #expect(KeyClassifier.normalizedForMatching(character: "я", keycode: 200) == "я")
    }

    // Spot-check the classic "type by physical position" case: a Greek layout
    // where the V-position key emits "ω" must normalise to "v".
    @Test func greekVKeyNormalizesToV() {
        #expect(KeyClassifier.normalizedForMatching(character: "ω", keycode: 9) == "v")
    }

    // MARK: - nxToFnKeycode (media keys)

    @Test func mediaKeysProjectOntoExpectedFKeys() {
        let expected: [Int: UInt16] = [
            0: 111, 1: 103, 2: 120, 3: 122, 7: 109,
            16: 100, 17: 101, 18: 98, 19: 101, 20: 98,
        ]
        #expect(KeyClassifier.nxToFnKeycode == expected)
    }

    // FAST/REWIND (19/20) must land on the same F-keys as NEXT/PREVIOUS
    // (17/18) so the wipe is hardware-generation agnostic.
    @Test func fastRewindShareFKeysWithNextPrevious() {
        #expect(KeyClassifier.nxToFnKeycode[19] == KeyClassifier.nxToFnKeycode[17])
        #expect(KeyClassifier.nxToFnKeycode[20] == KeyClassifier.nxToFnKeycode[18])
    }

    // Every projected F-key keycode is a real function keycode, so the wipe
    // lands on an actual on-screen F-key position.
    @Test func everyMediaProjectionIsAFunctionKeycode() {
        for fKeycode in KeyClassifier.nxToFnKeycode.values {
            #expect(KeyClassifier.functionKeycodes.contains(fKeycode))
        }
    }

    // An NX_KEYTYPE with no projection has no entry — the event tap routes
    // those through the unmapped sentinel instead.
    @Test func unmappedNXKeyTypeHasNoProjection() {
        // 10 = Mission Control-ish codes / others not in the map.
        #expect(KeyClassifier.nxToFnKeycode[10] == nil)
        #expect(KeyClassifier.nxToFnKeycode[999] == nil)
    }

    // MARK: - unmappedMediaKeycode sentinel

    @Test func sentinelIsUInt16Max() {
        #expect(KeyClassifier.unmappedMediaKeycode == UInt16.max)
    }

    // The sentinel must not collide with any real key: it's above every
    // function/control keycode and above the 179 KeyboardPositionMap ceiling.
    @Test func sentinelDoesNotCollideWithRealKeycodes() {
        #expect(!KeyClassifier.functionKeycodes.contains(KeyClassifier.unmappedMediaKeycode))
        #expect(!KeyClassifier.controlKeycodes.contains(KeyClassifier.unmappedMediaKeycode))
        #expect(KeyClassifier.unmappedMediaKeycode > 179)
        #expect(!KeyClassifier.nxToFnKeycode.values.contains(KeyClassifier.unmappedMediaKeycode))
    }

    // MARK: - table integrity

    // Function and control tables are disjoint — no keycode may bucket two
    // ways, or classify's ordering would silently mask a table bug.
    @Test func functionAndControlTablesAreDisjoint() {
        #expect(KeyClassifier.functionKeycodes.isDisjoint(with: KeyClassifier.controlKeycodes))
    }
}
