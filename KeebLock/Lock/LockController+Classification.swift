import AppKit

extension LockController {
    // MARK: - Keycode classification tables

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

    /// Modifier keycodes that fire as `flagsChanged` rather than
    /// `keyDown`. Press AND release fire the same event type for a
    /// given keycode, distinguished by tracking the held set in
    /// `pressedModifiers`. Includes both left/right variants for
    /// shift/cmd/opt/ctrl plus caps-lock and fn.
    static let modifierKeycodes: Set<UInt16> = [
        54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
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

    /// Bucket the keystroke counts in the breakdown. Each event path
    /// (regular keyDown, flagsChanged for modifiers, NX_SYSDEFINED
    /// for media keys) classifies once and routes through
    /// `recordWipingKeystroke` so the bookkeeping stays in sync.
    enum KeyBucket {
        case function, control, letter, number, symbol, media
    }

    /// Routes the wipe call based on the configured WipeMode. Random
    /// keeps the original behaviour. Positional looks up the on-screen
    /// position for the pressed keycode, scales the cell count by both
    /// the user's pixel-fineness setting AND the physical width of the
    /// key (a 5-unit spacebar clears five times the area of a 1-unit
    /// alphanumeric key — big keys feel big, small keys feel small).
    /// Unmapped keycodes (numpad-only keys, exotic hardware) skip the
    /// wipe entirely rather than falling back to random — random hits
    /// would pollute the visual feedback the user is reading to know
    /// which areas still need cleaning.
    private func dispatchWipe(for keycode: UInt16) {
        let settings = AppSettings.shared
        switch settings.wipeMode {
        case .random:
            windowManager.wipeOnAllScreens()
        case .positional:
            guard let mapping = KeyboardPositionMap.mapping(for: keycode) else {
                return
            }
            let baseCount = Double(settings.cellsPerAxis) / 14.0
            let count = max(1, Int((baseCount * mapping.widthUnits).rounded()))
            windowManager.wipeOnAllScreens(
                at: mapping.position,
                count: count,
                bounds: mapping.bounds
            )
        }
    }

    /// Single source of truth for "this physical key event counts as a
    /// wipe": bumps the counters, records the perf event, appends to
    /// the trail, throttle-saves the cleanmap, dispatches the wipe to
    /// the renderers, and fires audio/spark feedback.
    ///
    /// `skipWipe` keeps every bookkeeping step but skips the on-screen
    /// `dispatchWipe` call — for callers that have no physical key
    /// position to project the wipe onto (e.g. unmapped NX_SYSDEFINED
    /// codes) but still want counters/cleanmap/trail/fact-rotation to
    /// stay in sync with the regular wiping-keystroke path.
    func recordWipingKeystroke(keycode: UInt16,
                               bucket: KeyBucket,
                               eventLabel: String = "key",
                               suppressFeedback: Bool = false,
                               skipWipe: Bool = false) {
        keystrokeCount += 1
        let now = Date()
        // Tag-only by default; expanded to include keycode + normalised
        // keyboard position when verbose perf is on. The expanded form
        // exists to debug positional-mode behaviour (which key fired
        // which on-screen wipe). Verbose perf is opt-in and the user
        // is expected to know their snapshot will carry the keycode
        // sequence — they typed it on purpose to see it.
        if AppSettings.shared.verbosePerfEnabled {
            // Cursor position is included for every key event so a jump
            // between two consecutive keystrokes is immediately visible
            // in the snapshot's recentEvents ring. Truncated to ints —
            // sub-pixel precision adds noise without diagnostic value.
            let cx = Int(lastKeyDownCursor.x)
            let cy = Int(lastKeyDownCursor.y)
            if let mapping = KeyboardPositionMap.mapping(for: keycode) {
                PerfMetrics.shared.recordEvent(
                    "\(eventLabel) kc=\(keycode) cursor=(\(cx),\(cy)) pos=(\(String(format: "%.2f", mapping.position.x)),\(String(format: "%.2f", mapping.position.y))) w=\(String(format: "%.2f", mapping.widthUnits))"
                )
            } else {
                PerfMetrics.shared.recordEvent("\(eventLabel) kc=\(keycode) cursor=(\(cx),\(cy)) pos=unmapped")
            }
        } else {
            PerfMetrics.shared.recordEvent(eventLabel)
        }
        if keystrokeCount - lastFactRotationKeystroke >= Self.factRotationStride {
            lastFactRotationKeystroke = keystrokeCount
            factRotationTick &+= 1
        }

        switch bucket {
        case .function: functionKeyCount += 1
        case .control:  controlKeyCount += 1
        case .letter:   letterCount += 1
        case .number:   numberCount += 1
        case .symbol:   symbolCount += 1
        case .media:    mediaKeyCount += 1
        }

        sessionKeyCounts[keycode, default: 0] += 1
        overallKeyCounts[keycode, default: 0] += 1
        if sessionTrailStartedAt == nil { sessionTrailStartedAt = now.timeIntervalSince1970 }
        sessionTrail.append(TrailPoint(keycode: keycode, timestamp: now.timeIntervalSince1970))
        if sessionTrail.count > Self.trailMaxPoints {
            sessionTrail.removeFirst(sessionTrail.count - Self.trailMaxPoints)
        }
        // Throttled save during an active session: if the app is killed
        // (force-quit, panic, OOM) mid-lock the user still keeps every
        // chunk of keystrokes that crossed a save boundary. Stride 50
        // ≈ 4–5 s of brisk typing — small write fraction, small loss
        // window.
        wipesSinceLastCleanmapSave += 1
        if wipesSinceLastCleanmapSave >= Self.cleanmapSaveStride {
            saveOverallKeyCountsAsync()
            wipesSinceLastCleanmapSave = 0
        }
        PerfMetrics.shared.recordWipe()
        if !skipWipe {
            dispatchWipe(for: keycode)
        }
        if suppressFeedback {
            // Audio/sparks skipped (final unlock keystroke), but the
            // pause detector still needs to see the input.
            lastInputAt = now
        } else {
            triggerInputFeedback(now: now)
        }
    }

    func processKeyDown(chars: String, keycode: UInt16) {
        // Classify into one bucket. Order matters: F-keys and control keys
        // are checked first because they have keycodes but their printable
        // chars can be misleading (e.g. arrow keys produce private-use
        // codepoints that pass `isLetter` on some layouts).
        let bucket: KeyBucket
        if Self.functionKeycodes.contains(keycode) {
            bucket = .function
        } else if Self.controlKeycodes.contains(keycode) {
            bucket = .control
        } else if let first = chars.first, first.isLetter {
            bucket = .letter
        } else if let first = chars.first, first.isNumber {
            bucket = .number
        } else {
            // Punctuation and printable symbols that are neither letter nor
            // number: , . ; : ' " ! @ # $ % & * ( ) - _ = + [ ] { } etc.
            bucket = .symbol
        }

        // Run codeword detection BEFORE the wipe so we can suppress the
        // click feedback when this stroke is the one that unlocks —
        // otherwise the click and the unlock chime fire ~0 ms apart and
        // the user hears a muddy doubled sound.
        var willUnlock = false
        for ch in chars where ch.isLetter || ch.isNumber {
            // Non-Latin layouts (Greek/Cyrillic/etc.) produce isLetter chars
            // that never match ASCII codewords. Fall back to the US-layout
            // position so users can still type the codeword by key position.
            let normalized: Character = ch.isASCII ? ch : (Self.usLayoutMap[keycode] ?? ch)
            if matcher.feed(normalized) {
                willUnlock = true
                break
            }
        }

        recordWipingKeystroke(keycode: keycode, bucket: bucket, suppressFeedback: willUnlock)

        if willUnlock {
            stopLock()
            return
        }

        let progress = matcher.matchProgress
        if progress != codewordMatchProgress { codewordMatchProgress = progress }
    }
}
