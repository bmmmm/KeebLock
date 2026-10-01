import AppKit

extension LockController {
    // MARK: - Keycode classification

    /// Modifier keycodes that fire as `flagsChanged` rather than
    /// `keyDown`. Press AND release fire the same event type for a
    /// given keycode, distinguished by tracking the held set in
    /// `pressedModifiers`. Includes both left/right variants for
    /// shift/cmd/opt/ctrl plus caps-lock and fn. Stays here because the
    /// pairing/warmup routing around it is stateful; the pure lookup
    /// tables live in `KeyClassifier`.
    static let modifierKeycodes: Set<UInt16> = [
        54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
    ]

    /// The bucket type is owned by `KeyClassifier`; this alias keeps the
    /// existing call sites (`recordWipingKeystroke`, the event-tap media/
    /// modifier paths) terse.
    typealias KeyBucket = KeyClassifier.KeyBucket

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
        let bucket = KeyClassifier.classify(keycode: keycode, chars: chars)

        // Run codeword detection BEFORE the wipe so we can suppress the
        // click feedback when this stroke is the one that unlocks —
        // otherwise the click and the unlock chime fire ~0 ms apart and
        // the user hears a muddy doubled sound.
        var willUnlock = false
        for ch in chars where ch.isLetter || ch.isNumber {
            // Non-Latin layouts (Greek/Cyrillic/etc.) produce isLetter chars
            // that never match ASCII codewords. Fall back to the US-layout
            // position so users can still type the codeword by key position.
            let normalized = KeyClassifier.normalizedForMatching(character: ch, keycode: keycode)
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
