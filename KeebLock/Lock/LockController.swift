import AppKit
import Combine

final class LockController: ObservableObject {
    static let shared = LockController()

    @Published private(set) var isLocked: Bool = false
    @Published private(set) var keystrokeCount: Int = 0
    @Published private(set) var remainingSeconds: Int = 0
    @Published private(set) var totalSeconds: Int = 0
    @Published private(set) var currentCodeword: String = ""
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var keyCounts: [UInt16: Int] = [:]
    @Published private(set) var sparkTrigger: Int = 0
    // Keyboard breakdown
    @Published private(set) var letterCount: Int = 0
    @Published private(set) var numberCount: Int = 0
    @Published private(set) var fnKeyCount: Int = 0
    @Published private(set) var systemKeyCount: Int = 0
    @Published private(set) var otherKeyCount: Int = 0
    // Mouse breakdown
    @Published private(set) var leftClickCount: Int = 0
    @Published private(set) var rightClickCount: Int = 0
    @Published private(set) var middleClickCount: Int = 0
    @Published private(set) var backClickCount: Int = 0
    @Published private(set) var forwardClickCount: Int = 0
    @Published private(set) var scrollCount: Int = 0
    // Gestures
    @Published private(set) var spaceSwitchCount: Int = 0
    /// 3/4-finger trackpad swipes the user attempted while locked. Counts
    /// once per physical swipe (debounced) regardless of whether macOS
    /// would have completed the swipe's intended action.
    @Published private(set) var gestureAttemptCount: Int = 0

    @Published private(set) var codewordMatchProgress: Int = 0

    /// Monotonically increasing counter; HUDView modulos by `currentEntry.facts.count`
    /// to pick which fact to show. Lives here (not per-HUDView) so multi-monitor
    /// users see the same fact on every screen instead of each window
    /// independently rolling its own.
    @Published private(set) var factRotationTick: Int = 0
    private var lastFactRotationKeystroke: Int = 0
    private static let factRotationStride = 30

    var soundDiagnostic: String { soundPlayer.engineStatus + " · \(String(format: "%.1f", soundPlayer.engineLatencyMs)) ms latency · \(soundPlayer.engineSampleRate) Hz" }

    var eventTapInstalled: Bool { eventTap != nil }
    var spaceObserverInstalled: Bool { spaceObserver != nil }
    var lockWindowCount: Int { windowManager.windowCount }

    private static let fnKeycodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90,                     // F13–F20 (extended Apple keyboards)
    ]

    /// NX_KEYTYPE → F-key keycode. macOS fires media/brightness keys as
    /// system-defined events with NX_KEYTYPE codes (independent of regular
    /// keyboard keycodes). Mapping them to the F-key the user actually pressed
    /// lets the heatmap show "F1 was hit 12 times" regardless of fnState.
    private static let nxToFnKeycode: [Int: UInt16] = [
        0:  111, // SOUND_UP        → F12
        1:  103, // SOUND_DOWN      → F11
        2:  120, // BRIGHTNESS_UP   → F2
        3:  122, // BRIGHTNESS_DOWN → F1
        7:  109, // MUTE            → F10
        16: 100, // PLAY            → F8
        17: 101, // NEXT            → F9
        18: 98,  // PREVIOUS        → F7
    ]

    /// Hard-coded US-ANSI keycode → ASCII character map. Used as a fallback
    /// when the active keyboard layout produces non-ASCII characters
    /// (Greek, Cyrillic, Arabic, Hebrew, …) — without it those users would
    /// type the codeword by physical key position but feed the matcher
    /// non-Latin glyphs that never match. With this fallback the V key is
    /// always V for matching purposes regardless of layout. Only covers the
    /// alphanumeric range needed for codewords.
    private static let usLayoutMap: [UInt16: Character] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k",
        45: "n", 46: "m",
    ]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var matcher = CodewordMatcher(target: "")
    private var unlockTimer: Timer?
    private var lastKeystrokeAt: Date?
    private var lastScrollAt: Date?
    private var lastGestureAt: Date?
    private var spaceObserver: NSObjectProtocol?

    private let pauseDetectThreshold: TimeInterval = 30
    private let windowManager = LockWindowManager()
    private let soundPlayer = SoundPlayer()

    /// Legacy UserDefaults key that used to hold persisted heatmap data. We no
    /// longer write here — per-keycode counts are a biometric signature
    /// (typing rhythm, modifier usage, language) and shouldn't outlive the
    /// app's process. Keys retained as a constant only so the migration
    /// remove-on-launch can reference it.
    private static let legacyKeyCountsDefaultsKey = "heatmapKeyCounts"

    private var lockStartedAt: Date?
    private var bag = Set<AnyCancellable>()

    private init() {
        // One-time PII migration: scrub previously-persisted heatmap data on
        // app launch so existing installs lose the pattern leak too.
        UserDefaults.standard.removeObject(forKey: Self.legacyKeyCountsDefaultsKey)

        // Pipe sound settings live to the player so volume/file changes apply
        // without restarting the lock.
        let s = AppSettings.shared
        soundPlayer.setVolume(s.soundVolume)
        soundPlayer.setCustomFile(bookmark: s.soundFileBookmark)
        s.$soundVolume
            .sink { [weak self] in self?.soundPlayer.setVolume($0) }
            .store(in: &bag)
        s.$soundFileBookmark
            .sink { [weak self] in self?.soundPlayer.setCustomFile(bookmark: $0) }
            .store(in: &bag)
    }

    deinit {
        // Singleton; should never run. If it does, the event-tap callback
        // would dereference a dead pointer next time it fires — tear the tap
        // down explicitly so a freed instance can't be invoked.
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    // MARK: - Public

    func startLock(codeword: String, durationMinutes: Int) {
        guard !isLocked else { return }
        guard AccessibilityPermission.isGranted else {
            AccessibilityPermission.request()
            return
        }
        currentCodeword = codeword
        matcher = CodewordMatcher(target: codeword)
        keystrokeCount = 0
        letterCount = 0
        numberCount = 0
        fnKeyCount = 0
        systemKeyCount = 0
        otherKeyCount = 0
        leftClickCount = 0
        rightClickCount = 0
        middleClickCount = 0
        backClickCount = 0
        forwardClickCount = 0
        scrollCount = 0
        spaceSwitchCount = 0
        gestureAttemptCount = 0
        lastScrollAt = nil
        lastGestureAt = nil
        codewordMatchProgress = 0
        // Random starting tick so the same codeword doesn't always reveal
        // the same opening fact across sessions.
        factRotationTick = Int.random(in: 0..<10_000)
        lastFactRotationKeystroke = 0
        totalSeconds = max(60, durationMinutes * 60)
        remainingSeconds = totalSeconds
        lastKeystrokeAt = Date()
        isPaused = false

        // Bring up the tap FIRST. Only when it sticks do we mark the session
        // as live (lockStartedAt + PerfMetrics window) — otherwise a failed
        // attempt would leave a stale start-time and a never-stopped rate
        // timer behind, polluting the next successful session.
        guard installEventTap() else {
            DebugLog.log("startLock: installEventTap returned false — accessibility permission missing?")
            return
        }
        lockStartedAt = Date()
        PerfMetrics.shared.sessionStart()
        installSpaceObserver()
        DebugLog.log("startLock: codewordLen=\(codeword.count) durationMin=\(durationMinutes) tap=ok observer=ok")
        windowManager.show(
            controller: self,
            fixedBg: AppSettings.shared.backgroundSIMD,
            fixedPixel: AppSettings.shared.pixelSIMD,
            cellsPerAxis: AppSettings.shared.cellsPerAxis
        )
        isLocked = true
        startTimer()
    }

    func stopLock() {
        guard isLocked else { return }
        let secondsRun = max(0, totalSeconds - remainingSeconds)
        DebugLog.log("stopLock: ran=\(secondsRun)s/\(totalSeconds)s keys=\(keystrokeCount) (let=\(letterCount) num=\(numberCount) fn=\(fnKeyCount) sys=\(systemKeyCount) other=\(otherKeyCount)) mouse=\(leftClickCount + rightClickCount + middleClickCount + backClickCount + forwardClickCount) scroll=\(scrollCount) gestures=\(gestureAttemptCount) spaces=\(spaceSwitchCount)")
        if AppSettings.shared.unlockChimeEnabled {
            soundPlayer.playUnlockChime()
        }
        stopTimer()
        removeEventTap()
        removeSpaceObserver()
        soundPlayer.stop()
        recordSession()
        PerfMetrics.shared.sessionStop()
        // Defer window teardown to the next run loop pass — calling window.close()
        // inside a CGEventTap callback (even via MainActor) leaves AppKit autorelease
        // pools un-drained and causes EXC_BAD_ACCESS when SwiftUI starts updating.
        DispatchQueue.main.async {
            self.windowManager.hide()
            self.isLocked = false
        }
    }

    private func recordSession() {
        guard let started = lockStartedAt else { return }
        let session = CleaningSession(
            startedAt: started,
            durationSeconds: max(0, Int(Date().timeIntervalSince(started))),
            keystrokeCount: keystrokeCount,
            stageCount: windowManager.maxStage
        )
        CleaningHistory.shared.record(session)
        lockStartedAt = nil
    }

    func resetKeyCounts() {
        keyCounts = [:]
    }

    // MARK: - Timer (pause-aware)

    private func startTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in LockController.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        unlockTimer = timer
    }

    private func stopTimer() {
        unlockTimer?.invalidate()
        unlockTimer = nil
    }

    private func tick() {
        if let last = lastKeystrokeAt,
           Date().timeIntervalSince(last) > pauseDetectThreshold {
            isPaused = true
            return
        }
        isPaused = false
        // Auto-unlock is opt-in. When off, the timer just decorates the HUD and
        // never closes the lock — the user controls exit via codeword or button.
        guard AppSettings.shared.autoUnlockEnabled else { return }
        if remainingSeconds > 0 {
            remainingSeconds -= 1
        } else {
            stopLock()
        }
    }

    // MARK: - Event tap

    private func installEventTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)
                              | (1 << CGEventType.leftMouseDown.rawValue)
                              | (1 << CGEventType.rightMouseDown.rawValue)
                              | (1 << CGEventType.otherMouseDown.rawValue)
                              | (1 << CGEventType.scrollWheel.rawValue)
                              | (1 << 14) // NX_SYSDEFINED — media/brightness/etc. on Fn-layer
                              | (1 << 29) // NSEventType.gesture — continuous multi-touch
                              | (1 << 31) // NSEventType.swipe — discrete 3/4-finger swipe
                              // Earlier .screenSaver-only coverage relied on the OS
                              // swallowing gesture events at the window-level. On
                              // macOS 26+ that no longer holds for 3/4-finger swipes
                              // (Mission Control / between-spaces still completes),
                              // so we tap them here and swallow them at the source.
                              // Both rawValues come from NSEventType — CGEventType
                              // doesn't expose them but the underlying tap mask is
                              // bit-indexed and accepts the higher values fine.
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
                    PerfMetrics.shared.recordCallback(machTicks: PerfMetrics.now() &- t0)
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

    private func removeEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: - Space (Desktop) observer

    /// Watch for macOS Space switches (4-finger swipe, Ctrl+Arrow, Mission
    /// Control). The notification fires regardless of how the switch was
    /// triggered, so we get a reliable count even if the gesture itself never
    /// reaches our event tap.
    private func installSpaceObserver() {
        let center = NSWorkspace.shared.notificationCenter
        spaceObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isLocked else { return }
            self.spaceSwitchCount += 1
            self.triggerInputFeedback()
            // Re-promote our windows on the (possibly newly created) space.
            // canJoinAllSpaces should handle this automatically, but a manual
            // orderFront covers edge cases like spaces created via Mission
            // Control's "+" while we're already locked.
            self.windowManager.refreshSpaceCoverage()
        }
    }

    private func removeSpaceObserver() {
        if let token = spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        spaceObserver = nil
    }

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        if type == .leftMouseDown {
            leftClickCount += 1
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
            rightClickCount += 1
            triggerInputFeedback()
            return nil
        }
        if type == .otherMouseDown {
            // Button number: 2 = middle/wheel-click, 3 = back, 4 = forward (typical
            // 5-button mice). Higher numbers exist on some gaming mice — bucket as middle.
            let button = event.getIntegerValueField(.mouseEventButtonNumber)
            switch button {
            case 3: backClickCount += 1
            case 4: forwardClickCount += 1
            default: middleClickCount += 1
            }
            triggerInputFeedback()
            return nil
        }
        if type == .scrollWheel {
            // Trackpad/Magic-Mouse scrolls fire ~60 events/sec — debounce so a single
            // gesture maps to ~1 count + one feedback burst, not a machine-gun.
            let now = Date()
            if lastScrollAt == nil || now.timeIntervalSince(lastScrollAt!) > 0.25 {
                scrollCount += 1
                triggerInputFeedback()
            }
            lastScrollAt = now
            return nil
        }
        if type.rawValue == 29 || type.rawValue == 31 {
            // NSEventType.gesture (29) fires ~60 Hz throughout a continuous
            // multi-touch gesture; NSEventType.swipe (31) fires once per
            // discrete 3/4-finger directional swipe. Both are swallowed
            // (return nil) so Mission Control / Spaces / Expose can't
            // run while locked. Debounce so one physical swipe = one
            // count + one feedback burst, even though type 29 streams.
            let now = Date()
            if lastGestureAt == nil || now.timeIntervalSince(lastGestureAt!) > 0.4 {
                gestureAttemptCount += 1
                triggerInputFeedback()
            }
            lastGestureAt = now
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
                    systemKeyCount += 1
                    // Project onto the F-row so the visual heatmap shows
                    // these hits at the key the user physically pressed.
                    let nxKeycode = (nsEvent.data1 >> 16) & 0xFFFF
                    if let fKeycode = Self.nxToFnKeycode[nxKeycode] {
                        keyCounts[fKeycode, default: 0] += 1
                    }
                    triggerInputFeedback()
                }
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            var length = 0
            var unicode = [UniChar](repeating: 0, count: 4)
            event.keyboardGetUnicodeString(maxStringLength: 4,
                                           actualStringLength: &length,
                                           unicodeString: &unicode)
            let chars = String(utf16CodeUnits: unicode, count: length)
            processKeyDown(chars: chars, keycode: keycode)
        }
        return nil
    }

    /// Audio + visual feedback fired on every captured input (keystroke,
    /// mouse, fn/system key, etc.). Pixel wipe is intentionally NOT here —
    /// it stays exclusive to keyDown so non-keyboard inputs don't grant free
    /// cleaning progress.
    private func triggerInputFeedback() {
        if AppSettings.shared.soundEnabled { soundPlayer.play() }
        if AppSettings.shared.effectEnabled { sparkTrigger += 1 }
    }

    private func processKeyDown(chars: String, keycode: UInt16) {
        keystrokeCount += 1
        lastKeystrokeAt = Date()
        if keystrokeCount - lastFactRotationKeystroke >= Self.factRotationStride {
            lastFactRotationKeystroke = keystrokeCount
            factRotationTick &+= 1
        }

        // Classify into one bucket. Order matters: F-keys are checked first because
        // they have keycodes but produce no printable chars on most layouts.
        if Self.fnKeycodes.contains(keycode) {
            fnKeyCount += 1
        } else if let first = chars.first, first.isLetter {
            letterCount += 1
        } else if let first = chars.first, first.isNumber {
            numberCount += 1
        } else {
            // Esc, Tab, Return, Space, Arrows, Delete, Punctuation that's neither
            // letter nor number, etc.
            otherKeyCount += 1
        }

        keyCounts[keycode, default: 0] += 1
        PerfMetrics.shared.recordWipe()
        windowManager.wipeOnAllScreens()
        triggerInputFeedback()

        for ch in chars where ch.isLetter || ch.isNumber {
            // Non-Latin layouts (Greek/Cyrillic/etc.) produce isLetter chars
            // that never match ASCII codewords. Fall back to the US-layout
            // position so users can still type the codeword by key position.
            let normalized: Character = ch.isASCII ? ch : (Self.usLayoutMap[keycode] ?? ch)
            if matcher.feed(normalized) {
                stopLock()
                return
            }
        }
        let progress = matcher.matchProgress
        if progress != codewordMatchProgress { codewordMatchProgress = progress }
    }
}
