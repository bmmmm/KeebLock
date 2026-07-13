import AppKit

extension LockController {
    // MARK: - Event tap

    func installEventTap() -> Bool {
        // NSEventType raw values — verified against AppKit's NSEvent.h:
        //   gesture=29  magnify=30  swipe=31  rotate=18  beginGesture=19
        //   endGesture=20  smartMagnify=32  pressure=34
        // Earlier code had rotate/beginGesture/endGesture/smartMagnify wrong
        // (32/33/34/35), which left rotate uncovered, made every smartMagnify
        // misclassify as rotate, and caused phantom counters.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)
                              | (1 << CGEventType.leftMouseDown.rawValue)
                              | (1 << CGEventType.rightMouseDown.rawValue)
                              | (1 << CGEventType.otherMouseDown.rawValue)
                              | (1 << CGEventType.mouseMoved.rawValue)
                              | (1 << CGEventType.leftMouseDragged.rawValue)
                              | (1 << CGEventType.rightMouseDragged.rawValue)
                              | (1 << CGEventType.otherMouseDragged.rawValue)
                              | (1 << CGEventType.scrollWheel.rawValue)
                              | (1 << 14) // NX_SYSDEFINED — media/brightness/etc. on Fn-layer
                              | (1 << 18) // NSEventType.rotate — 2-finger rotation
                              | (1 << 19) // NSEventType.beginGesture
                              | (1 << 20) // NSEventType.endGesture
                              | (1 << 29) // NSEventType.gesture — continuous multi-touch
                              | (1 << 30) // NSEventType.magnify — 2-finger pinch
                              | (1 << 31) // NSEventType.swipe — discrete 3/4-finger swipe
                              | (1 << 32) // NSEventType.smartMagnify — double-tap zoom
                              // .screenSaver-level alone no longer prevents 3/4-finger
                              // swipes on macOS 26+ (the OS dispatches them via the
                              // WindowServer/Dock path that runs above app event taps).
                              // We still tap and swallow here — for keyboard hotkeys
                              // (Ctrl+Up/Left/Right), pinch, rotate, smart-magnify it
                              // works; trackpad space-swipes succeed only partially,
                              // with activeSpaceDidChange + refreshSpaceCoverage as
                              // reactive recovery.
        // passUnretained is safe here because LockController is a process-wide
        // singleton (`shared`) — the userInfo pointer is valid for the entire
        // app lifetime. If the singleton invariant ever changes, switch to
        // passRetained + matching takeRetainedValue or risk UAF in the callback.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let t0 = PerfMetrics.now()
                    let controller = Unmanaged<LockController>.fromOpaque(refcon).takeUnretainedValue()
                    let result = controller.handleEvent(type: type, event: event)
                    PerfMetrics.shared.recordCallback(machTicks: PerfMetrics.now() &- t0, type: type)
                    return result
                }
            },
            userInfo: userInfo
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    func removeEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// The event tap could not be re-enabled (almost always: Accessibility
    /// permission revoked while locked). Break out of the dead lock instead of
    /// trapping the user, and explain why. Dispatched off the tap callback so
    /// the modal alert and window teardown don't run inside the C callback.
    func handleDeadTap() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLocked else { return }
            self.stopLock()
            // stopLock() defers windowManager.hide() to the next run-loop turn
            // (see its comment) to avoid tearing down AppKit windows from
            // inside the CGEventTap callback stack. This closure is already
            // running on its own dispatched turn, off that stack, so hide the
            // lock windows synchronously here — otherwise runModal() below
            // blocks with the .screenSaver-level lock window still up, and
            // the alert starts occluded behind it. hide() is idempotent, so
            // stopLock()'s own deferred hide() call is a harmless no-op once
            // it runs.
            self.windowManager.hide()
            let alert = NSAlert()
            alert.messageText = "KeebLock unlocked itself"
            alert.informativeText = "The keyboard hook stopped working — most likely Accessibility "
                + "permission was revoked. Re-grant it under System Settings › Privacy & Security › "
                + "Accessibility before locking again."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let reason = (type == .tapDisabledByTimeout) ? "timeout" : "user input / permission change"
            if type == .tapDisabledByTimeout {
                PerfMetrics.shared.recordTapTimeout()
            }
            DebugLog.log("tap: disabled by \(reason) — re-enabling")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                // Verify the re-enable actually took. If Accessibility
                // permission was revoked mid-session, tapEnable is a no-op and
                // the tap stays dead: keystrokes pass through and the user can
                // no longer type the codeword to unlock — trapped behind a
                // non-functional full-screen lock. Detect that and force-unlock.
                if !CGEvent.tapIsEnabled(tap: tap) {
                    DebugLog.log("tap: re-enable FAILED (\(reason)) — forcing unlock so the user isn't trapped")
                    handleDeadTap()
                }
            }
            return nil
        }

        if type == .leftMouseDown {
            // In-lock snapshot button. The overlay paints a button at the
            // top-right of the main screen; we intercept the mousedown at
            // the matching coordinate region and write the snapshot
            // ourselves — no pass-through to SwiftUI required, no click
            // counter bump, no spark feedback (it's a debug action, not
            // user input we'd report on the cleanmap).
            if isInsideInlineSnapshotRegion(event.location) {
                triggerInlineSnapshot()
                return nil
            }
            if isInWarmup { return nil }
            leftClickCount += 1
            PerfMetrics.shared.recordEvent("mouseL")
            triggerInputFeedback()
            // Pass through once the user has typed ≥ half the codeword — the unlock
            // button becomes visible and clickable at that threshold.
            let halfLen = max(1, (currentCodeword.count + 1) / 2)
            if codewordMatchProgress >= halfLen {
                return Unmanaged.passUnretained(event)
            }
            return nil
        }
        if type == .rightMouseDown {
            if isInWarmup { return nil }
            rightClickCount += 1
            PerfMetrics.shared.recordEvent("mouseR")
            triggerInputFeedback()
            return nil
        }
        if type == .otherMouseDown {
            if isInWarmup { return nil }
            // Button number: 2 = middle/wheel-click, 3 = back, 4 = forward (typical
            // 5-button mice). Higher numbers exist on some gaming mice — bucket as middle.
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            switch button {
            case 3: backClickCount += 1
            case 4: forwardClickCount += 1
            default: middleClickCount += 1
            }
            PerfMetrics.shared.recordEvent("mouseAux btn=\(button)")
            triggerInputFeedback()
            return nil
        }
        if type == .mouseMoved
            || type == .leftMouseDragged
            || type == .rightMouseDragged
            || type == .otherMouseDragged {
            // Pass through. We used to return nil here to "freeze" the cursor
            // for the app underneath, but the live cursor-flicker / brief
            // wait-cursor flash that appeared after the first mouse move +
            // typing burst was traced to this swallow: under combined key +
            // mouse load, the nil returns made WindowServer treat our tap as
            // unresponsive to mouse events and throttle its cursor refresh,
            // surfacing as a 1-frame visual stutter. Letting the events
            // through eliminates the symptom (verified by hypothesis-B
            // toggle test 2026-05-20).
            //
            // App-level hover effects under the lock window stay frozen
            // anyway because the lock window is the topmost full-screen
            // `.screenSaver`-level window at every cursor position, so
            // WindowServer routes mouseMoved to it — not to the apps
            // underneath. Our lock window doesn't enable
            // `acceptsMouseMovedEvents`, so the event reaches no responder.
            if AppSettings.shared.verbosePerfEnabled {
                let loc = event.location
                checkAnyEventCursorJump(loc, eventLabel: "mouseMoved")
                // 1-in-30 sampling so the cursor trajectory still lands
                // in the event ring without drowning out keyDown events.
                mouseMovedSampleCount &+= 1
                if mouseMovedSampleCount % 30 == 0 {
                    PerfMetrics.shared.recordEvent(
                        "mouseMoved cursor=(\(Int(loc.x)),\(Int(loc.y)))"
                    )
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .scrollWheel {
            if isInWarmup { return nil }
            // Trackpad/Magic-Mouse scrolls fire ~60 events/sec — debounce so a single
            // gesture maps to ~1 count + one feedback burst, not a machine-gun.
            // 0.4 s is conservative: a quick two-finger flick still registers
            // as one scroll, but a slow continuous drag no longer machine-guns
            // the counter every quarter-second.
            let now = Date()
            if lastScrollAt == nil || now.timeIntervalSince(lastScrollAt!) > 0.4 {
                scrollCount += 1
                PerfMetrics.shared.recordEvent("scroll")
                triggerInputFeedback()
            }
            lastScrollAt = now
            return nil
        }
        if type.rawValue == 29 {
            // NSEventType.gesture — continuous multi-touch stream (~60 Hz)
            // while a finger is on the trackpad / Magic Mouse, even without
            // movement. No counter / sound / spark — but we DO bump
            // lastInputAt so the pause-detection timer doesn't trip on a
            // user who's actively touching the Magic Mouse but hasn't
            // clicked or typed. Without this update the auto-unlock timer
            // freezes after `pauseDetectThreshold` even though the user is
            // physically present at the keyboard.
            lastInputAt = Date()
            return nil
        }
        if type.rawValue == 31 {
            // NSEventType.swipe — discrete 3/4-finger directional swipe.
            // The OS emits one event per physical swipe. Debounce against
            // the space observer so a swipe that ALSO triggers an
            // activeSpaceDidChange (typical case on macOS 26+) only counts
            // once across both code paths.
            if isInWarmup { return nil }
            let now = Date()
            if lastSwipeAt == nil || now.timeIntervalSince(lastSwipeAt!) > 0.4 {
                swipeCount += 1
                PerfMetrics.shared.recordEvent("swipe")
                triggerInputFeedback()
            }
            lastSwipeAt = now
            return nil
        }
        if type.rawValue == 30 {
            // NSEventType.magnify — pinch-to-zoom. macOS only emits this
            // when it has classified a touch session as a pinch attempt
            // (you can't hold two static fingers on a Magic Mouse and get
            // .magnify — that path produces .gesture 29 instead, which we
            // already swallow silently). So we accept every .magnify; the
            // 1.0 s debounce collapses one physical pinch (which streams
            // ~60 Hz) into one count.
            if isInWarmup { return nil }
            let now = Date()
            if lastPinchAt == nil || now.timeIntervalSince(lastPinchAt!) > 1.0 {
                pinchCount += 1
                PerfMetrics.shared.recordEvent("pinch")
                triggerInputFeedback()
            }
            lastPinchAt = now
            return nil
        }
        if type.rawValue == 18 {
            // NSEventType.rotate — same accounting as .magnify. macOS gates
            // emission on intent-classification, so any rotate we see is
            // already real; debounce collapses the per-frame stream to
            // one count.
            if isInWarmup { return nil }
            let now = Date()
            if lastRotateAt == nil || now.timeIntervalSince(lastRotateAt!) > 1.0 {
                rotateCount += 1
                PerfMetrics.shared.recordEvent("rotate")
                triggerInputFeedback()
            }
            lastRotateAt = now
            return nil
        }
        if type.rawValue == 32 {
            // NSEventType.smartMagnify — discrete double-tap zoom. Folded
            // into pinchCount because it's the same conceptual gesture for
            // the user; counted directly with no debounce.
            if isInWarmup { return nil }
            pinchCount += 1
            PerfMetrics.shared.recordEvent("smartMagnify")
            triggerInputFeedback()
            return nil
        }
        if type.rawValue == 19 || type.rawValue == 20 {
            // beginGesture / endGesture — touch-session boundary events.
            // Swallow silently; the discrete branches above own the count.
            // Bump lastInputAt so the pause timer doesn't trip on a user
            // who's mid-touch-session without producing a discrete event.
            lastInputAt = Date()
            return nil
        }

        if type.rawValue == 14 {
            // NX_SYSDEFINED: subtype 8 = aux control buttons (brightness, volume,
            // mission control, spotlight, media keys on Fn-layer). Other subtypes
            // (power button, mouse aux buttons) pass through untouched.
            PerfMetrics.shared.recordNSEventAlloc()
            if let nsEvent = NSEvent(cgEvent: event), nsEvent.subtype.rawValue == 8 {
                // data1 layout: high 16 = keycode, low 16 = flags.
                // Within flags: bits 8..15 = key state (0x0A = down, 0x0B = up),
                // bit 0 = repeat. Count only non-repeat key-down to match a
                // single physical press.
                let flags = nsEvent.data1 & 0xFFFF
                let keyState = (flags & 0xFF00) >> 8
                let isRepeat = (flags & 0x1) != 0
                if keyState == 0x0A && !isRepeat {
                    // Project onto the F-row so the visual cleanmap and
                    // the positional wipe both target the F-key the user
                    // actually pressed regardless of fnState. Unmapped
                    // NX_KEYTYPE codes (Mission Control, Launchpad,
                    // Dictation, Do-Not-Disturb on modern Apple
                    // keyboards) route through the same
                    // recordWipingKeystroke bookkeeping as every other
                    // wiping keystroke — counters, cleanmap, trail, fact
                    // rotation — via the unmappedMediaKeycode sentinel;
                    // only the visual wipe is skipped (skipWipe: true)
                    // because there's no F-key position to project onto.
                    let nxKeycode = (nsEvent.data1 >> 16) & 0xFFFF
                    if let fKeycode = Self.nxToFnKeycode[nxKeycode] {
                        recordWipingKeystroke(
                            keycode: fKeycode,
                            bucket: .media,
                            eventLabel: "mediaKey nx=\(nxKeycode)"
                        )
                    } else {
                        recordWipingKeystroke(
                            keycode: Self.unmappedMediaKeycode,
                            bucket: .media,
                            eventLabel: "mediaKey nx=\(nxKeycode) unmapped",
                            skipWipe: true
                        )
                    }
                }
                return nil
            }
            // Any other NX_SYSDEFINED subtype (power key, mouse aux, sleep,
            // etc.) is passed through untouched — we cannot consume it.
            // CONFIRMED 2026-06-02: a power-button press produces NO event here
            // (no sysDefined count on press). On Apple Silicon / T2 Macs the
            // power button is wired to the SMC and handled by powerd below the
            // session event tap, so it never reaches an app-level tap at all.
            // Interception is impossible at the app layer — KeebLock cannot stop
            // the power button from sleeping / locking the Mac. Logging retained
            // (gated on verbose perf) as a diagnostic for other hardware.
            if AppSettings.shared.verbosePerfEnabled {
                let subtype = NSEvent(cgEvent: event)?.subtype.rawValue ?? -1
                PerfMetrics.shared.recordEvent("sysDefined subtype=\(subtype) (passed through)")
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            // Modifier press/release. Both fire the same flagsChanged
            // event for a given keycode, so dedupe via `pressedModifiers`:
            // first event for a keycode = press → wipe; second = release
            // → ignore. Non-modifier keycodes that arrive here (rare —
            // some special keys also trigger flagsChanged) are skipped.
            let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard Self.modifierKeycodes.contains(keycode) else { return nil }
            // Caps Lock (57) toggles: macOS emits ONE flagsChanged per
            // physical press (the lock-state change), not a press/release
            // pair. Routing it through the pairing logic below classified
            // every second press as a "release" and dropped its wipe.
            // Count each event as a press and keep it out of
            // `pressedModifiers` so it can't desync the pairing set.
            if keycode == 57 {
                if !isInWarmup {
                    recordWipingKeystroke(keycode: keycode, bucket: .control)
                }
                return nil
            }
            if pressedModifiers.contains(keycode) {
                pressedModifiers.remove(keycode)
                return nil
            }
            pressedModifiers.insert(keycode)
            // Track the press in `pressedModifiers` even during warmup so the
            // matching release is still recognised as a release — only the wipe
            // recording is suppressed. Gating the whole branch on isInWarmup (as
            // before) dropped warmup-era presses from the set, so the post-warmup
            // release fell through to the insert+record path: a spurious wipe,
            // and worse, it inverted press/release parity for that modifier for
            // the rest of the session.
            if !isInWarmup {
                recordWipingKeystroke(keycode: keycode, bucket: .control)
            }
            return nil
        }

        if type == .keyDown {
            // ⌘⌥Esc escape hatch. KeebLock is a cleaning aid, not a kiosk lock
            // (see threat model) — the user must always keep a way out if the
            // codeword path ever wedges. Passing the combo through to the
            // system's Force Quit handler does NOT work during a lock: we
            // swallow the Cmd/Opt flagsChanged events (so WindowServer never
            // registers the chord) and, even if it did, the Force Quit window
            // would open BEHIND our full-screen .screenSaver-level lock window —
            // invisible. So we handle the chord ourselves and unlock: that frees
            // the user reliably and tears down the occluding window (a second
            // ⌘⌥Esc then reaches the system normally). Detect Escape (keycode 53)
            // with both Command and Option held, checking BOTH our tracked
            // modifier set (robust — flagsChanged populates it even in warmup)
            // and the event's own flags. Not counted as a wipe.
            let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keycode == 53 {
                let cmdHeld = pressedModifiers.contains(54) || pressedModifiers.contains(55)
                let optHeld = pressedModifiers.contains(58) || pressedModifiers.contains(61)
                let flagsHaveBoth = event.flags.contains([.maskCommand, .maskAlternate])
                if (cmdHeld && optHeld) || flagsHaveBoth {
                    DebugLog.log("keyDown: ⌘⌥Esc escape hatch — unlocking (tracked=\(cmdHeld && optHeld) flags=\(flagsHaveBoth))")
                    stopLock()
                    return nil
                }
            }
            // Skip OS-generated key repeats (held-down key). Repeats are
            // already swallowed by the trailing `return nil`; we just
            // refrain from counting / matching / sounding them. Without
            // this filter, holding spacebar inflates `keystrokeCount`,
            // machine-guns the audio click, fills the cleanmap with bogus
            // data, and lets a held-letter run carry the codeword
            // suffix-matcher to a spurious unlock.
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                // Capture cursor location BEFORE processing — the verbose-perf
                // tag in recordWipingKeystroke will append it. This is what
                // makes the "cursor jumps during typing burst" symptom
                // visible in the snapshot.
                lastKeyDownCursor = event.location
                if AppSettings.shared.verbosePerfEnabled {
                    checkAnyEventCursorJump(event.location, eventLabel: "keyDown")
                }
                var length = 0
                var unicode = [UniChar](repeating: 0, count: 4)
                event.keyboardGetUnicodeString(maxStringLength: 4,
                                               actualStringLength: &length,
                                               unicodeString: &unicode)
                let chars = String(utf16CodeUnits: unicode, count: length)
                processKeyDown(chars: chars, keycode: keycode)
            }
        }
        return nil
    }
}
