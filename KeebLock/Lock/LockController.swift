import AppKit
import Combine
import Observation

@Observable
final class LockController {
    @MainActor static let shared = LockController()

    private(set) var isLocked: Bool = false
    private(set) var keystrokeCount: Int = 0
    private(set) var remainingSeconds: Int = 0
    private(set) var totalSeconds: Int = 0
    private(set) var currentCodeword: String = ""
    private(set) var isPaused: Bool = false
    /// Per-keycode counts for the *current* lock session. Reset on each
    /// startLock(). Lives in memory only.
    private(set) var sessionKeyCounts: [UInt16: Int] = [:]
    /// Per-keycode counts accumulated across every lock session on this
    /// machine. Persisted to UserDefaults on each stopLock and re-loaded
    /// on launch. The user can clear it via the Heatmap view's Reset
    /// button. Privacy-trade-off acknowledged: this is keystroke-pattern
    /// data and stays on-disk, scoped to this user's UserDefaults — never
    /// leaves the machine.
    private(set) var overallKeyCounts: [UInt16: Int] = [:]
    private(set) var sparkTrigger: Int = 0
    // Keyboard breakdown
    private(set) var letterCount: Int = 0
    private(set) var numberCount: Int = 0
    private(set) var fnKeyCount: Int = 0
    private(set) var systemKeyCount: Int = 0
    private(set) var otherKeyCount: Int = 0
    // Mouse breakdown
    private(set) var leftClickCount: Int = 0
    private(set) var rightClickCount: Int = 0
    private(set) var middleClickCount: Int = 0
    private(set) var backClickCount: Int = 0
    private(set) var forwardClickCount: Int = 0
    private(set) var scrollCount: Int = 0
    // Gestures
    private(set) var spaceSwitchCount: Int = 0
    /// 3/4-finger trackpad swipes the user attempted while locked. Counts
    /// once per physical swipe (debounced) regardless of whether macOS
    /// would have completed the swipe's intended action.
    private(set) var gestureAttemptCount: Int = 0
    /// 2-finger pinch (magnify) attempts. NSEventType 30, debounced.
    private(set) var pinchCount: Int = 0
    /// 2-finger rotation attempts. NSEventType 32, debounced.
    private(set) var rotateCount: Int = 0

    private(set) var codewordMatchProgress: Int = 0

    /// Bumps each time the in-lock "snapshot" button (rendered by
    /// LockOverlayDebug at the top-right) is clicked. The overlay
    /// watches this for changes to flash a "SAVED" toast — the actual
    /// snapshot write happens synchronously in triggerInlineSnapshot().
    private(set) var snapshotPulse: Int = 0

    /// Monotonically increasing counter; HUDView modulos by `currentEntry.facts.count`
    /// to pick which fact to show. Lives here (not per-HUDView) so multi-monitor
    /// users see the same fact on every screen instead of each window
    /// independently rolling its own.
    private(set) var factRotationTick: Int = 0
    @ObservationIgnored private var lastFactRotationKeystroke: Int = 0
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

    // @ObservationIgnored: these are internal state, never read from a
    // SwiftUI body. Without the annotation, mutating them through the
    // event-tap callback would still post observation tracking events
    // even though no view reads them — pure cost, no benefit.
    @ObservationIgnored private var eventTap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var matcher = CodewordMatcher(target: "")
    @ObservationIgnored private var unlockTimer: Timer?
    @ObservationIgnored private var lastKeystrokeAt: Date?
    @ObservationIgnored private var lastScrollAt: Date?
    @ObservationIgnored private var lastGestureAt: Date?
    @ObservationIgnored private var lastPinchAt: Date?
    @ObservationIgnored private var lastRotateAt: Date?
    @ObservationIgnored private var spaceObserver: NSObjectProtocol?

    @ObservationIgnored private let pauseDetectThreshold: TimeInterval = 30
    @ObservationIgnored private let windowManager = LockWindowManager()
    @ObservationIgnored private let soundPlayer = SoundPlayer()

    /// Legacy UserDefaults key — single combined dictionary blob. Replaced
    /// by `overallKeyCountsKey` below; folded into overall on first launch
    /// after the migration (so existing users don't lose their accumulated
    /// counts), then removed.
    private static let legacyKeyCountsDefaultsKey = "heatmapKeyCounts"
    /// Key for the persistent overall-heatmap blob.
    private static let overallKeyCountsKey = "heatmapOverallKeyCounts"

    @ObservationIgnored private var lockStartedAt: Date?
    @ObservationIgnored private var bag = Set<AnyCancellable>()

    private init() {
        loadOverallKeyCounts()

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
        pinchCount = 0
        rotateCount = 0
        // Per-session heatmap starts fresh; overall heatmap accumulates.
        sessionKeyCounts = [:]
        lastScrollAt = nil
        lastGestureAt = nil
        lastPinchAt = nil
        lastRotateAt = nil
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
        DebugLog.log("stopLock: ran=\(secondsRun)s/\(totalSeconds)s keys=\(keystrokeCount) (let=\(letterCount) num=\(numberCount) fn=\(fnKeyCount) sys=\(systemKeyCount) other=\(otherKeyCount)) mouse=\(leftClickCount + rightClickCount + middleClickCount + backClickCount + forwardClickCount) scroll=\(scrollCount) swipes=\(gestureAttemptCount) pinch=\(pinchCount) rotate=\(rotateCount) spaces=\(spaceSwitchCount)")
        if AppSettings.shared.unlockChimeEnabled {
            soundPlayer.playUnlockChime()
        }
        stopTimer()
        removeEventTap()
        removeSpaceObserver()
        soundPlayer.stop()
        recordSession()
        saveOverallKeyCounts()
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

    /// Wipe the current-session heatmap. Doesn't touch overall.
    func resetSessionHeatmap() {
        sessionKeyCounts = [:]
    }

    /// Wipe the persistent overall heatmap and the on-disk blob.
    func resetOverallHeatmap() {
        overallKeyCounts = [:]
        UserDefaults.standard.removeObject(forKey: Self.overallKeyCountsKey)
    }

    // MARK: - In-lock snapshot button (paired with LockOverlayDebug)

    /// Geometry of the snapshot button rendered by LockOverlayDebug at
    /// the top-right of the main screen. Kept in one place so the
    /// event-tap region check and the SwiftUI button position can't
    /// drift apart.
    static let inlineSnapshotButtonWidth:  CGFloat = 140
    static let inlineSnapshotButtonHeight: CGFloat = 28
    static let inlineSnapshotButtonMargin: CGFloat = 12

    /// `point` is in CGEvent global coordinates (top-left origin).
    /// Returns true when the user clicked inside the on-screen snapshot
    /// button — only when the overlay is on, otherwise the button isn't
    /// drawn and we don't want to silently swallow a click on empty
    /// space at the top-right.
    private func isInsideInlineSnapshotRegion(_ point: CGPoint) -> Bool {
        guard AppSettings.shared.lockOverlayDebugLevel != .off else { return false }
        guard let screen = NSScreen.main else { return false }
        let w = Self.inlineSnapshotButtonWidth
        let h = Self.inlineSnapshotButtonHeight
        let m = Self.inlineSnapshotButtonMargin
        // CGEvent.location for the main display: (0, 0) is the top-left
        // pixel; x grows right, y grows down. The button sits in the
        // top-right corner with `m` margin from both edges.
        let region = CGRect(
            x: screen.frame.maxX - w - m,
            y: m,
            width: w,
            height: h
        )
        return region.contains(point)
    }

    /// Write a full DebugLog snapshot to disk and bump snapshotPulse so
    /// the overlay can flash a "SAVED" toast. PerfMetrics records this
    /// as an event so the timestamp lands in the snapshot's own Recent
    /// Events section — handy for cross-correlating "I clicked here"
    /// against the latency curve.
    private func triggerInlineSnapshot() {
        let snap = DebugLog.snapshot()
        DebugLog.writeForced(snap)
        snapshotPulse &+= 1
        DebugLog.log("inline snapshot pulse=\(snapshotPulse)")
        PerfMetrics.shared.recordEvent("snapshot")
    }

    // MARK: - Heatmap persistence

    private func loadOverallKeyCounts() {
        // Pick up the new blob first.
        if let data = UserDefaults.standard.data(forKey: Self.overallKeyCountsKey),
           let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
            PerfMetrics.shared.recordJSONDecode()
            overallKeyCounts = Dictionary(uniqueKeysWithValues: dict.compactMap { key, val -> (UInt16, Int)? in
                guard let code = UInt16(key) else { return nil }
                return (code, val)
            })
        }
        // One-time migration: existing users had data under the legacy key
        // before the privacy-pass dropped persistence. Now that overall-
        // heatmap persistence is back (per-user request), fold whatever's
        // still under the legacy key into overall and remove the legacy
        // entry so we don't double-count on the next launch.
        if let legacyData = UserDefaults.standard.data(forKey: Self.legacyKeyCountsDefaultsKey),
           let legacyDict = try? JSONDecoder().decode([String: Int].self, from: legacyData) {
            PerfMetrics.shared.recordJSONDecode()
            for (key, val) in legacyDict {
                guard let code = UInt16(key) else { continue }
                overallKeyCounts[code, default: 0] += val
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyKeyCountsDefaultsKey)
        }
    }

    private func saveOverallKeyCounts() {
        let stringDict = Dictionary(uniqueKeysWithValues:
            overallKeyCounts.map { (String($0.key), $0.value) }
        )
        if let data = try? JSONEncoder().encode(stringDict) {
            PerfMetrics.shared.recordJSONEncode()
            UserDefaults.standard.set(data, forKey: Self.overallKeyCountsKey)
            PerfMetrics.shared.recordUserDefaultsWrite()
        }
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
                              | (1 << 30) // NSEventType.magnify — 2-finger pinch
                              | (1 << 31) // NSEventType.swipe — discrete 3/4-finger swipe
                              | (1 << 32) // NSEventType.rotate — 2-finger rotation
                              | (1 << 33) // NSEventType.beginGesture
                              | (1 << 34) // NSEventType.endGesture
                              | (1 << 35) // NSEventType.smartMagnify — double-tap zoom
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
            PerfMetrics.shared.recordEvent("space")
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
            // In-lock snapshot button. The overlay paints a button at the
            // top-right of the main screen; we intercept the mousedown at
            // the matching coordinate region and write the snapshot
            // ourselves — no pass-through to SwiftUI required, no click
            // counter bump, no spark feedback (it's a debug action, not
            // user input we'd report on the heatmap).
            if isInsideInlineSnapshotRegion(event.location) {
                triggerInlineSnapshot()
                return nil
            }
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
            rightClickCount += 1
            PerfMetrics.shared.recordEvent("mouseR")
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
            PerfMetrics.shared.recordEvent("mouseAux btn=\(button)")
            triggerInputFeedback()
            return nil
        }
        if type == .scrollWheel {
            // Trackpad/Magic-Mouse scrolls fire ~60 events/sec — debounce so a single
            // gesture maps to ~1 count + one feedback burst, not a machine-gun.
            let now = Date()
            if lastScrollAt == nil || now.timeIntervalSince(lastScrollAt!) > 0.25 {
                scrollCount += 1
                PerfMetrics.shared.recordEvent("scroll")
                triggerInputFeedback()
            }
            lastScrollAt = now
            return nil
        }
        if type.rawValue == 29 || type.rawValue == 31 {
            // NSEventType.gesture (29) streams ~60 Hz; NSEventType.swipe (31)
            // is a discrete 3/4-finger directional swipe. Swallowed (return
            // nil) so Mission Control / Spaces / Expose can't trigger while
            // locked — though for trackpad space-swipes macOS 26+ may still
            // complete the action above our tap. Debounce so one physical
            // swipe = one count + one feedback burst, even though 29 streams.
            let now = Date()
            if lastGestureAt == nil || now.timeIntervalSince(lastGestureAt!) > 0.4 {
                gestureAttemptCount += 1
                PerfMetrics.shared.recordEvent("swipe")
                triggerInputFeedback()
            }
            lastGestureAt = now
            return nil
        }
        if type.rawValue == 30 {
            // NSEventType.magnify — pinch-to-zoom. Streams while pinching;
            // debounce to one count per physical pinch.
            let now = Date()
            if lastPinchAt == nil || now.timeIntervalSince(lastPinchAt!) > 0.4 {
                pinchCount += 1
                PerfMetrics.shared.recordEvent("pinch")
                triggerInputFeedback()
            }
            lastPinchAt = now
            return nil
        }
        if type.rawValue == 32 {
            // NSEventType.rotate — 2-finger rotation. Streams; debounce.
            let now = Date()
            if lastRotateAt == nil || now.timeIntervalSince(lastRotateAt!) > 0.4 {
                rotateCount += 1
                PerfMetrics.shared.recordEvent("rotate")
                triggerInputFeedback()
            }
            lastRotateAt = now
            return nil
        }
        if type.rawValue == 33 || type.rawValue == 34 || type.rawValue == 35 {
            // beginGesture / endGesture / smartMagnify — bookend events
            // around touch sessions. Swallow silently; the streaming branches
            // above already counted the underlying physical gesture, so we'd
            // only inflate counts by handling these.
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
                    PerfMetrics.shared.recordEvent("sysKey")
                    // Project onto the F-row so the visual heatmap shows
                    // these hits at the key the user physically pressed.
                    let nxKeycode = (nsEvent.data1 >> 16) & 0xFFFF
                    if let fKeycode = Self.nxToFnKeycode[nxKeycode] {
                        sessionKeyCounts[fKeycode, default: 0] += 1
                        overallKeyCounts[fKeycode, default: 0] += 1
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
        PerfMetrics.shared.recordEvent("key kc=\(keycode)")
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

        sessionKeyCounts[keycode, default: 0] += 1
        overallKeyCounts[keycode, default: 0] += 1
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
