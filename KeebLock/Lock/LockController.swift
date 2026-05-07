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
    /// on launch. The user can clear it via the Cleanmap view's Reset
    /// button. Privacy-trade-off acknowledged: this is keystroke-pattern
    /// data and stays on-disk, scoped to this user's UserDefaults — never
    /// leaves the machine.
    private(set) var overallKeyCounts: [UInt16: Int] = [:]
    private(set) var sparkTrigger: Int = 0
    // Keyboard breakdown
    private(set) var letterCount: Int = 0
    private(set) var numberCount: Int = 0
    /// Punctuation, !@#$%&, all printable non-letter / non-number chars.
    private(set) var symbolCount: Int = 0
    /// Esc, Tab, Return, Space, Backspace, Delete, Arrows, Home/End/PgUp/PgDn.
    private(set) var controlKeyCount: Int = 0
    /// F1–F20.
    private(set) var functionKeyCount: Int = 0
    /// Brightness, Volume, Play/Next/Prev — emitted by NX_SYSDEFINED subtype 8.
    private(set) var mediaKeyCount: Int = 0
    // Mouse breakdown
    private(set) var leftClickCount: Int = 0
    private(set) var rightClickCount: Int = 0
    private(set) var middleClickCount: Int = 0
    private(set) var backClickCount: Int = 0
    private(set) var forwardClickCount: Int = 0
    private(set) var scrollCount: Int = 0
    // Gestures
    /// Discrete 3/4-finger trackpad swipes — counts both NSEventType.swipe
    /// (31) when the tap sees it AND `activeSpaceDidChange` notifications
    /// (which is how 4-finger swipes manifest on macOS 26+ where the OS
    /// dispatches the gesture above our event tap). Debounced across both
    /// paths so a swipe that triggers a Space change counts once, not twice.
    private(set) var swipeCount: Int = 0
    /// 2-finger pinch (NSEventType.magnify = 30) plus double-tap zoom
    /// (NSEventType.smartMagnify = 32). Magnify streams during a pinch, so
    /// debounced; smartMagnify is discrete and counted directly.
    private(set) var pinchCount: Int = 0
    /// 2-finger rotation attempts. NSEventType.rotate = 18, debounced.
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

    private static let functionKeycodes: Set<UInt16> = [
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, // F1–F12
        105, 107, 113, 106, 64, 79, 80, 90,                     // F13–F20 (extended Apple keyboards)
    ]

    /// Non-printable navigation / editing / whitespace keys. Distinguished
    /// from `symbolCount` so the breakdown shows e.g. heavy Backspace usage
    /// separately from punctuation.
    private static let controlKeycodes: Set<UInt16> = [
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
    @ObservationIgnored private var lastInputAt: Date?
    @ObservationIgnored private var lastScrollAt: Date?
    @ObservationIgnored private var lastSwipeAt: Date?
    @ObservationIgnored private var lastPinchAt: Date?
    @ObservationIgnored private var lastRotateAt: Date?
    @ObservationIgnored private var spaceObserver: NSObjectProtocol?

    @ObservationIgnored private let pauseDetectThreshold: TimeInterval = 30
    /// Window after lockStartedAt during which non-keyboard events are still
    /// swallowed by the tap but not counted/sounded/sparked. Eats the burst
    /// from `windowManager.show()` activating the lock window — Magic Mouse
    /// emits a `.gesture` stream the moment the cursor crosses the new
    /// window, and `activeSpaceDidChange` may fire from the AppKit promotion
    /// itself. 0.7 s is the longest of those bursts I've measured.
    @ObservationIgnored private let warmupGracePeriod: TimeInterval = 0.7
    @ObservationIgnored private let windowManager = LockWindowManager()
    @ObservationIgnored private let soundPlayer = SoundPlayer()

    /// Uralt UserDefaults key — single combined dictionary blob from the
    /// very first heatmap implementation. Folded into the current blob on
    /// first launch after that migration, then removed.
    private static let legacyKeyCountsDefaultsKey = "heatmapKeyCounts"
    /// Previous current-blob key (pre-rename). Folded into
    /// `cleanmapKeyCountsKey` once on the upgrade that introduced the
    /// rename, then removed. Kept as a constant only for that migration.
    private static let legacyHeatmapOverallKey = "heatmapOverallKeyCounts"
    /// Key for the persistent overall-cleanmap blob (post-rename).
    private static let cleanmapKeyCountsKey = "cleanmapOverallKeyCounts"
    /// One-shot flag set after the uralt → overall fold. Without it, a
    /// downgrade-then-upgrade cycle (old build re-writes the legacy key,
    /// new build re-folds on next launch) silently double-counts.
    private static let legacyMigrationDoneKey = "heatmapMigratedFromLegacy"
    /// One-shot flag set after the heatmap → cleanmap rename fold. Same
    /// downgrade-protection rationale as above.
    private static let renameToCleanmapDoneKey = "renamedFromHeatmapToCleanmap"

    @ObservationIgnored private var lockStartedAt: Date?
    /// Set synchronously at the top of `stopLock()` so a re-entry from a
    /// different code path (e.g. timer auto-unlock firing between codeword
    /// match and the deferred `isLocked = false`) doesn't run the teardown
    /// sequence twice — which would otherwise double-play the unlock chime
    /// and double-record the session.
    @ObservationIgnored private var isStopping: Bool = false
    /// Counter for the throttled overall-cleanmap save during an active
    /// session. Incremented per wipe; flushed every Nth or on
    /// `applicationWillTerminate`. Without periodic flush a crash mid-
    /// session loses every wipe accumulated since the last
    /// `stopLock()` save.
    @ObservationIgnored private var wipesSinceLastCleanmapSave: Int = 0
    @ObservationIgnored private static let cleanmapSaveStride: Int = 50
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

        // Final flush of the cumulative cleanmap on app termination so a
        // user who quits mid-session keeps the wipes since the last
        // throttled save. Token is intentionally not stored — singleton's
        // observer lives for the process lifetime.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.saveOverallKeyCounts()
        }
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
        symbolCount = 0
        controlKeyCount = 0
        functionKeyCount = 0
        mediaKeyCount = 0
        leftClickCount = 0
        rightClickCount = 0
        middleClickCount = 0
        backClickCount = 0
        forwardClickCount = 0
        scrollCount = 0
        swipeCount = 0
        pinchCount = 0
        rotateCount = 0
        // Per-session cleanmap starts fresh; overall cleanmap accumulates.
        sessionKeyCounts = [:]
        lastScrollAt = nil
        lastSwipeAt = nil
        lastPinchAt = nil
        lastRotateAt = nil
        codewordMatchProgress = 0
        // Random starting tick so the same codeword doesn't always reveal
        // the same opening fact across sessions.
        factRotationTick = Int.random(in: 0..<10_000)
        lastFactRotationKeystroke = 0
        totalSeconds = max(60, durationMinutes * 60)
        remainingSeconds = totalSeconds
        lastInputAt = Date()
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
        guard isLocked, !isStopping else { return }
        isStopping = true
        // Real elapsed time. The previous `totalSeconds - remainingSeconds`
        // expression read 0 whenever auto-unlock was off, because the
        // timer never decrements `remainingSeconds` in that mode — so
        // every "ran=…" log line lied about the session length.
        let secondsRun = lockStartedAt.map { max(0, Int(Date().timeIntervalSince($0))) } ?? 0
        DebugLog.log("stopLock: ran=\(secondsRun)s/\(totalSeconds)s keys=\(keystrokeCount) (let=\(letterCount) num=\(numberCount) sym=\(symbolCount) ctl=\(controlKeyCount) fn=\(functionKeyCount) med=\(mediaKeyCount)) mouse=\(leftClickCount + rightClickCount + middleClickCount + backClickCount + forwardClickCount) scroll=\(scrollCount) swipes=\(swipeCount) pinch=\(pinchCount) rotate=\(rotateCount)")
        if AppSettings.shared.unlockChimeEnabled {
            soundPlayer.playUnlockChime()
        }
        stopTimer()
        removeEventTap()
        removeSpaceObserver()
        soundPlayer.stop()
        recordSession()
        saveOverallKeyCounts()
        wipesSinceLastCleanmapSave = 0
        PerfMetrics.shared.sessionStop()
        // Defer window teardown to the next run loop pass — calling window.close()
        // inside a CGEventTap callback (even via MainActor) leaves AppKit autorelease
        // pools un-drained and causes EXC_BAD_ACCESS when SwiftUI starts updating.
        DispatchQueue.main.async {
            self.windowManager.hide()
            self.isLocked = false
            self.isStopping = false
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

    /// Clear the current-session cleanmap. Doesn't touch overall.
    func resetSessionCleanmap() {
        sessionKeyCounts = [:]
    }

    /// Clear the persistent overall cleanmap and the on-disk blob.
    func resetOverallCleanmap() {
        overallKeyCounts = [:]
        UserDefaults.standard.removeObject(forKey: Self.cleanmapKeyCountsKey)
    }

    // MARK: - In-lock snapshot button (paired with LockOverlayDebug)

    /// Geometry of the snapshot button rendered by LockOverlayDebug at
    /// the top-right of the main screen. Kept in one place so the
    /// event-tap region check and the SwiftUI button position can't
    /// drift apart.
    static let inlineSnapshotButtonWidth:  CGFloat = 140
    static let inlineSnapshotButtonHeight: CGFloat = 28
    static let inlineSnapshotButtonMargin: CGFloat = 12

    /// `point` is in CGEvent global coordinates (top-left origin of the
    /// PRIMARY display = `NSScreen.screens.first`, with Y growing down).
    /// Returns true when the user clicked inside an on-screen snapshot
    /// button — only when the overlay is on, otherwise the button isn't
    /// drawn and we don't want to silently swallow clicks at the
    /// top-right corner of any display.
    ///
    /// `LockOverlayDebug` paints a snapshot button at the top-right of
    /// EVERY lock window — one per display. The user can click any of
    /// them. We translate each screen's top-right rectangle from
    /// NSScreen arrangement coords (Y up, anchored at the screen
    /// arrangement origin) into CGEvent coords (Y down, anchored at
    /// the primary display's top-left) and accept the click if it
    /// lands in any of those rectangles. Single-display setups fall
    /// out trivially because the loop has just one iteration with
    /// primary == main.
    private func isInsideInlineSnapshotRegion(_ point: CGPoint) -> Bool {
        guard AppSettings.shared.lockOverlayDebugLevel != .off else { return false }
        guard let primary = NSScreen.screens.first else { return false }
        let w = Self.inlineSnapshotButtonWidth
        let h = Self.inlineSnapshotButtonHeight
        let m = Self.inlineSnapshotButtonMargin
        // primary.frame.minX is 0 by Apple's convention (NSScreen.screens.first
        // is anchored at the global origin), but keep the subtraction explicit
        // so the math survives any future change in that contract.
        for screen in NSScreen.screens {
            let region = CGRect(
                x: screen.frame.maxX - m - w - primary.frame.minX,
                y: primary.frame.maxY - screen.frame.maxY + m,
                width: w,
                height: h
            )
            if region.contains(point) { return true }
        }
        return false
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

    // MARK: - Cleanmap persistence

    private func loadOverallKeyCounts() {
        // Pick up the current blob first.
        if let data = UserDefaults.standard.data(forKey: Self.cleanmapKeyCountsKey),
           let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
            PerfMetrics.shared.recordJSONDecode()
            overallKeyCounts = Dictionary(uniqueKeysWithValues: dict.compactMap { key, val -> (UInt16, Int)? in
                guard let code = UInt16(key) else { return nil }
                return (code, val)
            })
        }
        // One-shot rename migration: pre-rename data lived under
        // `heatmapOverallKeyCounts`. Fold (additive) into the new key
        // and remove the old blob so a downgrade can't double-count
        // on a subsequent upgrade.
        if !UserDefaults.standard.bool(forKey: Self.renameToCleanmapDoneKey) {
            if let data = UserDefaults.standard.data(forKey: Self.legacyHeatmapOverallKey),
               let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
                PerfMetrics.shared.recordJSONDecode()
                for (key, val) in dict {
                    guard let code = UInt16(key) else { continue }
                    overallKeyCounts[code, default: 0] += val
                }
                UserDefaults.standard.removeObject(forKey: Self.legacyHeatmapOverallKey)
            }
            UserDefaults.standard.set(true, forKey: Self.renameToCleanmapDoneKey)
        }
        // Uralt one-shot migration: existing users had data under the
        // legacy single-blob key before the privacy-pass dropped
        // persistence. Now that overall persistence is back (per-user
        // request), fold whatever's still under the legacy key in and
        // remove it. Same one-shot flag protection.
        guard !UserDefaults.standard.bool(forKey: Self.legacyMigrationDoneKey) else { return }
        if let legacyData = UserDefaults.standard.data(forKey: Self.legacyKeyCountsDefaultsKey),
           let legacyDict = try? JSONDecoder().decode([String: Int].self, from: legacyData) {
            PerfMetrics.shared.recordJSONDecode()
            for (key, val) in legacyDict {
                guard let code = UInt16(key) else { continue }
                overallKeyCounts[code, default: 0] += val
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyKeyCountsDefaultsKey)
        }
        UserDefaults.standard.set(true, forKey: Self.legacyMigrationDoneKey)
    }

    private func saveOverallKeyCounts() {
        let stringDict = Dictionary(uniqueKeysWithValues:
            overallKeyCounts.map { (String($0.key), $0.value) }
        )
        if let data = try? JSONEncoder().encode(stringDict) {
            PerfMetrics.shared.recordJSONEncode()
            UserDefaults.standard.set(data, forKey: Self.cleanmapKeyCountsKey)
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
        if let last = lastInputAt,
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
            // queue: .main guarantees the closure runs on the main thread,
            // but the Notification API surface is nonisolated so the
            // compiler can't see that. assumeIsolated lets us call into
            // @MainActor APIs (windowManager / PerfMetrics / mutations on
            // self) without an async hop that would defer the recovery
            // beyond the next frame.
            MainActor.assumeIsolated {
                guard let self, self.isLocked else { return }
                // Re-promote our windows on the (possibly newly created) space.
                // canJoinAllSpaces should handle this automatically, but a manual
                // orderFront covers edge cases like spaces created via Mission
                // Control's "+" while we're already locked. This must run even
                // during warmup — it's the recovery path, not user-attributed.
                self.windowManager.refreshSpaceCoverage()
                // The notification can fire from AppKit's own window-promotion
                // path during lock startup; ignore those so the user doesn't see
                // a phantom swipe on a clean start.
                guard !self.isInWarmup else { return }
                // Space changes are how 4-finger swipes manifest on macOS 26+
                // (the OS dispatches the gesture above our event tap). Map
                // them onto swipeCount with a debounce so a `.swipe` (31) and
                // its follow-up activeSpaceDidChange don't double-count.
                let now = Date()
                if self.lastSwipeAt == nil || now.timeIntervalSince(self.lastSwipeAt!) > 0.4 {
                    self.swipeCount += 1
                    PerfMetrics.shared.recordEvent("swipe (space)")
                    self.triggerInputFeedback()
                }
                self.lastSwipeAt = now
            }
        }
    }

    /// True for the first `warmupGracePeriod` seconds after a successful
    /// `startLock`. The event tap still swallows everything during this
    /// window — we just refrain from counting / sounding / sparking on
    /// non-keyboard events to absorb the burst that the lock-window
    /// activation itself produces (Magic Mouse `.gesture` stream, AppKit-
    /// induced `activeSpaceDidChange`, etc.). Keyboard is exempt elsewhere
    /// so the user can start typing the codeword immediately.
    private var isInWarmup: Bool {
        guard let started = lockStartedAt else { return false }
        return Date().timeIntervalSince(started) < warmupGracePeriod
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
            // Silent swallow. These events fire 60–120×/s while the user
            // moves the cursor; counting them would inflate metrics and
            // sounding/sparking on every pixel of motion would be worse
            // than the leak we're closing. Cursor rendering itself is
            // WindowServer-level and unaffected; what changes is that
            // app-level hover behaviours (button highlights, tooltips,
            // NSToolbar tracking, URL previews) under the lock window
            // stop responding, which is the intended freeze.
            return nil
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
                    mediaKeyCount += 1
                    PerfMetrics.shared.recordEvent("mediaKey")
                    // Project onto the F-row so the visual cleanmap shows
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
            // Skip OS-generated key repeats (held-down key). Repeats are
            // already swallowed by the trailing `return nil`; we just
            // refrain from counting / matching / sounding them. Without
            // this filter, holding spacebar inflates `keystrokeCount`,
            // machine-guns the audio click, fills the cleanmap with bogus
            // data, and lets a held-letter run carry the codeword
            // suffix-matcher to a spurious unlock.
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
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

    /// Routes the wipe call based on the configured WipeMode. Random
    /// keeps the original behaviour. Positional looks up the on-screen
    /// position for the pressed keycode and clears `count` cells there
    /// on every screen — count scales with cells-per-axis so the wipe
    /// stays roughly one keyboard-column wide regardless of pixel size
    /// (1 cell at coarse settings, 2–3 cells at fine settings). Falls
    /// back to random when the keycode isn't in the keyboard layout
    /// (exotic hardware keys), so keystrokes never go without feedback.
    private func dispatchWipe(for keycode: UInt16) {
        let settings = AppSettings.shared
        switch settings.wipeMode {
        case .random:
            windowManager.wipeOnAllScreens()
        case .positional:
            if let pos = KeyboardPositionMap.normalizedPosition(for: keycode) {
                let cellsX = settings.cellsPerAxis
                let count = max(1, cellsX / 14)
                windowManager.wipeOnAllScreens(at: pos, count: count)
            } else {
                windowManager.wipeOnAllScreens()
            }
        }
    }

    /// Audio + visual feedback fired on every captured input (keystroke,
    /// mouse, fn/system key, etc.). Pixel wipe is intentionally NOT here —
    /// it stays exclusive to keyDown so non-keyboard inputs don't grant free
    /// cleaning progress.
    ///
    /// Side-effect: also bumps `lastInputAt` so the pause-detection timer
    /// resets on any input, not just keystrokes. Without this the auto-
    /// unlock timer would freeze after `pauseDetectThreshold` seconds of
    /// no-typing even when the user is actively mousing / clicking /
    /// scrolling around the keyboard during cleaning.
    private func triggerInputFeedback() {
        lastInputAt = Date()
        if AppSettings.shared.soundEnabled { soundPlayer.play() }
        if AppSettings.shared.effectEnabled { sparkTrigger += 1 }
    }

    private func processKeyDown(chars: String, keycode: UInt16) {
        keystrokeCount += 1
        lastInputAt = Date()
        // Tag-only — no keycode. The verbose-perf event ring is dumped
        // into snapshots that users may share for support; including
        // the physical keycode there leaks the codeword's key-position
        // sequence to anyone who reads the file.
        PerfMetrics.shared.recordEvent("key")
        if keystrokeCount - lastFactRotationKeystroke >= Self.factRotationStride {
            lastFactRotationKeystroke = keystrokeCount
            factRotationTick &+= 1
        }

        // Classify into one bucket. Order matters: F-keys and control keys
        // are checked first because they have keycodes but their printable
        // chars can be misleading (e.g. arrow keys produce private-use
        // codepoints that pass `isLetter` on some layouts).
        if Self.functionKeycodes.contains(keycode) {
            functionKeyCount += 1
        } else if Self.controlKeycodes.contains(keycode) {
            controlKeyCount += 1
        } else if let first = chars.first, first.isLetter {
            letterCount += 1
        } else if let first = chars.first, first.isNumber {
            numberCount += 1
        } else {
            // Punctuation and printable symbols that are neither letter nor
            // number: , . ; : ' " ! @ # $ % & * ( ) - _ = + [ ] { } etc.
            symbolCount += 1
        }

        sessionKeyCounts[keycode, default: 0] += 1
        overallKeyCounts[keycode, default: 0] += 1
        // Throttled save during an active session: if the app is killed
        // (force-quit, panic, OOM) mid-lock the user still keeps every
        // chunk of keystrokes that crossed a save boundary. Stride 50
        // ≈ 4–5 s of brisk typing — small write fraction, small loss
        // window.
        wipesSinceLastCleanmapSave += 1
        if wipesSinceLastCleanmapSave >= Self.cleanmapSaveStride {
            saveOverallKeyCounts()
            wipesSinceLastCleanmapSave = 0
        }
        PerfMetrics.shared.recordWipe()
        dispatchWipe(for: keycode)
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
