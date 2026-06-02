import AppKit
import Combine
import Observation

/// One wipe in the temporal trail rendered by `TrailmapView`. Stored
/// as keycode + Unix timestamp so the view can both place the point
/// (via `KeyboardPositionMap`) and colour it by age.
struct TrailPoint: Codable {
    let keycode: UInt16
    let timestamp: TimeInterval
}

/// NSObject adapter so `CADisplayLink`'s target/@objc selector contract
/// can call into a Swift closure that lives on LockController. The
/// closure runs on the main thread (CADisplayLink delivers on whatever
/// runloop it was added to — we use `.main`), which matches the
/// LockController's MainActor isolation by location.
@MainActor
final class DisplayLinkBridge: NSObject {
    let callback: () -> Void
    init(callback: @escaping () -> Void) { self.callback = callback }
    @objc func fire() { callback() }
}

@Observable
final class LockController {
    @MainActor static let shared = LockController()

    private(set) var isLocked: Bool = false
    private(set) var remainingSeconds: Int = 0
    private(set) var totalSeconds: Int = 0
    private(set) var currentCodeword: String = ""
    private(set) var isPaused: Bool = false

    /// 1 Hz pulse driven by the existing pause/unlock timer. Views that
    /// display per-event counters subscribe to this instead of to the
    /// counters themselves — the counters live as @ObservationIgnored so
    /// the per-keystroke / per-mousedown mutations don't fire view-update
    /// cascades through the registrar. Mirrors PerfMetrics.tickSeq.
    ///
    /// Per-event mutation of an @Observable property goes through
    /// _$observationRegistrar.withMutation, which synchronously notifies
    /// every access tracker registered for that keyPath. With 8-10
    /// observable mutations per keyDown (counters + bucket + dict +
    /// trail + spark + codewordMatchProgress) and multiple views
    /// observing (HUDView, LockOverlayDebug, CleanmapView, TrailmapView),
    /// the keyDown callback was driving a downstream body-eval storm
    /// that pushed mouse-callback p99 latency from ~20 µs to ~2.2 ms in
    /// the mousekeymix perf test — the MainActor saturated under
    /// combined load. 1 Hz refresh on counters is more than enough for
    /// readouts that show running totals.
    private(set) var displayTick: Int = 0

    /// Per-keycode counts for the *current* lock session. Reset on each
    /// startLock(). Lives in memory only.
    @ObservationIgnored private(set) var sessionKeyCounts: [UInt16: Int] = [:]
    /// Per-keycode counts accumulated across every lock session on this
    /// machine. Persisted to UserDefaults on each stopLock and re-loaded
    /// on launch. The user can clear it via the Cleanmap view's Reset
    /// button. Privacy-trade-off acknowledged: this is keystroke-pattern
    /// data and stays on-disk, scoped to this user's UserDefaults — never
    /// leaves the machine.
    @ObservationIgnored private(set) var overallKeyCounts: [UInt16: Int] = [:]
    /// Ordered sequence of (keycode, timestamp) pairs for the *current*
    /// lock session — drives the Trailmap view's polyline rendering.
    /// Reset on each startLock(). Lives in memory only; not persisted
    /// (the cross-session view was deemed not useful enough to justify
    /// the on-disk footprint).
    @ObservationIgnored private(set) var sessionTrail: [TrailPoint] = []
    @ObservationIgnored private(set) var keystrokeCount: Int = 0
    private(set) var sparkTrigger: Int = 0
    // Keyboard breakdown — all @ObservationIgnored: per-keyDown bumps were
    // multiplying the per-event publish count under the hot path. Views
    // refresh on displayTick.
    @ObservationIgnored private(set) var letterCount: Int = 0
    @ObservationIgnored private(set) var numberCount: Int = 0
    /// Punctuation, !@#$%&, all printable non-letter / non-number chars.
    @ObservationIgnored private(set) var symbolCount: Int = 0
    /// Esc, Tab, Return, Space, Backspace, Delete, Arrows, Home/End/PgUp/PgDn.
    @ObservationIgnored private(set) var controlKeyCount: Int = 0
    /// F1–F20.
    @ObservationIgnored private(set) var functionKeyCount: Int = 0
    /// Brightness, Volume, Play/Next/Prev — emitted by NX_SYSDEFINED subtype 8.
    @ObservationIgnored private(set) var mediaKeyCount: Int = 0
    // Mouse breakdown — also off the observation path. Same rationale.
    @ObservationIgnored private(set) var leftClickCount: Int = 0
    @ObservationIgnored private(set) var rightClickCount: Int = 0
    @ObservationIgnored private(set) var middleClickCount: Int = 0
    @ObservationIgnored private(set) var backClickCount: Int = 0
    @ObservationIgnored private(set) var forwardClickCount: Int = 0
    @ObservationIgnored private(set) var scrollCount: Int = 0
    // Gestures
    /// Discrete 3/4-finger trackpad swipes — counts both NSEventType.swipe
    /// (31) when the tap sees it AND `activeSpaceDidChange` notifications
    /// (which is how 4-finger swipes manifest on macOS 26+ where the OS
    /// dispatches the gesture above our event tap). Debounced across both
    /// paths so a swipe that triggers a Space change counts once, not twice.
    @ObservationIgnored private(set) var swipeCount: Int = 0
    /// 2-finger pinch (NSEventType.magnify = 30) plus double-tap zoom
    /// (NSEventType.smartMagnify = 32). Magnify streams during a pinch, so
    /// debounced; smartMagnify is discrete and counted directly.
    @ObservationIgnored private(set) var pinchCount: Int = 0
    /// 2-finger rotation attempts. NSEventType.rotate = 18, debounced.
    @ObservationIgnored private(set) var rotateCount: Int = 0

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
    /// Per-screen wipe-renderer state for diagnostic snapshots; empty
    /// when no lock is active.
    var screenWipeStates: [WipeRenderer.State] { windowManager.screenStates() }

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

    /// Modifier keycodes that fire as `flagsChanged` rather than
    /// `keyDown`. Press AND release fire the same event type for a
    /// given keycode, distinguished by tracking the held set in
    /// `pressedModifiers`. Includes both left/right variants for
    /// shift/cmd/opt/ctrl plus caps-lock and fn.
    private static let modifierKeycodes: Set<UInt16> = [
        54, 55, 56, 57, 58, 59, 60, 61, 62, 63,
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
        // Modern Apple Magic Keyboards emit FAST/REWIND for the same
        // physical F-keys older keyboards report as NEXT/PREVIOUS.
        // Map them to the same F-keys so the wipe lands in the same
        // place regardless of which hardware generation is in use.
        19: 101, // FAST            → F9
        20: 98,  // REWIND          → F7
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
    /// Drives the displayTick at the screen's native refresh rate so view
    /// re-evals batch into frames the system was already going to render —
    /// no separate MainActor preemption window like a Timer would create.
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var displayLinkBridge: DisplayLinkBridge?
    @ObservationIgnored private var lastInputAt: Date?
    /// Modifier keycodes currently held. flagsChanged fires once on
    /// press and once on release for the same keycode; tracking the
    /// set lets us count press only.
    @ObservationIgnored private var pressedModifiers: Set<UInt16> = []
    @ObservationIgnored private var lastScrollAt: Date?
    @ObservationIgnored private var lastSwipeAt: Date?
    @ObservationIgnored private var lastPinchAt: Date?
    @ObservationIgnored private var lastRotateAt: Date?
    @ObservationIgnored private var spaceObserver: NSObjectProtocol?
    /// Watches for display arrangement changes (monitor hot-plug/unplug,
    /// resolution or primary-display change) so we can rebuild the lock
    /// surface across the new screen set while locked.
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    /// Coalesces the burst of `didChangeScreenParameters` notifications a
    /// single hot-plug emits into one rebuild.
    @ObservationIgnored private var screenChangeWork: DispatchWorkItem?
    /// Cursor location at the most recent keyDown, captured from
    /// `CGEvent.location`. Used purely by the verbose-perf event-ring
    /// log so we can see if the cursor jumps between two consecutive
    /// keystrokes during a burst — the "Mauszeiger springt nach
    /// schnellem Tippen" symptom we're chasing.
    @ObservationIgnored private var lastKeyDownCursor: CGPoint = .zero
    /// Counter to sample 1-in-N mouseMoved events into the verbose-perf
    /// event ring. Without sampling, mouseMoved at 60-120 Hz would push
    /// every keyDown out of the 80-entry ring within a second.
    @ObservationIgnored private var mouseMovedSampleCount: Int = 0
    /// Cursor position from the most recent mouseMoved/dragged event,
    /// used by the auto-snapshot jump detector. Different from
    /// `lastKeyDownCursor` because we want to track every mouse update,
    /// not just keystroke samples.
    /// Throttle for the auto-snapshot trigger. Without it a single jump
    /// can fire dozens of snapshots as the cursor settles into its new
    /// position — we only want one per discrete jump event.
    @ObservationIgnored private var lastAutoSnapshotAt: TimeInterval = 0
    /// Unified cursor tracker across ALL events (keyDown, mouseMoved,
    /// clicks). The original mouseMoved-only tracker missed jumps that
    /// happen between consecutive keystrokes without an intervening
    /// mouseMoved — which is exactly the live symptom we're chasing.
    /// `event.location` is set on every CGEvent regardless of type, so
    /// this fires on whichever event-type arrives next.
    @ObservationIgnored private var lastAnyEventCursor: CGPoint = .zero
    @ObservationIgnored private var lastAnyEventAt: TimeInterval = 0

    /// 60 Hz gate on sparkTrigger increments. The visual effect already
    /// rate-limits spawn() inside SparkOverlayView to 60 Hz, but the
    /// upstream sparkTrigger mutation drives a LockView → SparkOverlayView
    /// body re-eval *per keystroke* — capping the bump at 60 Hz collapses
    /// that cascade for autorepeat / perf-test bursts without altering
    /// the visible effect (normal typing stays well under 60 Hz).
    @ObservationIgnored private var lastSparkTriggerAt: TimeInterval = 0
    private static let sparkTriggerMinInterval: TimeInterval = 1.0 / 60.0

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
    /// FIFO cap for the session trail. 5 000 wipes is roughly 15-20
    /// minutes of brisk typing, well past the visual density at which
    /// the polyline becomes unreadable. Memory cost is
    /// `count * (UInt16 + Double)` — about 50 KB at the cap.
    private static let trailMaxPoints = 5000

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
    /// Background queue for the throttled cleanmap save so the JSON encode
    /// and UserDefaults write never land inside an event-tap callback.
    /// Serial: ordering of saves matters (later snapshots must overwrite
    /// earlier ones, not race with them).
    @ObservationIgnored private static let cleanmapSaveQueue = DispatchQueue(
        label: "de.6bm.KeebLock.cleanmap-save",
        qos: .utility
    )
    @ObservationIgnored private var bag = Set<AnyCancellable>()

    private init() {
        loadOverallKeyCounts()

        // Pipe sound settings live to the player so volume/file changes apply
        // without restarting the lock.
        let s = AppSettings.shared
        soundPlayer.setVolume(s.soundVolume)
        soundPlayer.setCustomFile(bookmark: s.soundFileBookmark)
        // Deliver on main so SoundPlayer's custom-file state (customPlayer,
        // customScopedURL, customBookmark) is only ever mutated on the main
        // thread — the same thread play() runs on (the event tap dispatches to
        // CFRunLoopGetMain). A @Published change published from a background
        // context would otherwise race play()'s reads of that state.
        s.$soundVolume
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.soundPlayer.setVolume($0) }
            .store(in: &bag)
        s.$soundFileBookmark
            .receive(on: DispatchQueue.main)
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
        // Defensive normalisation: the keystroke matcher is only ever fed ASCII
        // letters and digits — processKeyDown filters on isLetter || isNumber AND
        // remaps any non-ASCII input to its US-layout ASCII key, so a non-ASCII
        // glyph never reaches the matcher. A codeword with spaces/punctuation, an
        // accented letter, or an empty value could therefore never be matched,
        // trapping the user behind the lock with only ⌘⌥Esc as a way out. Strip
        // to the matchable ASCII-alphanumeric subset here; if nothing is left,
        // fall back to a random shipped codeword (same policy as AppSettings'
        // empty-codeword fallback) so a lock is never armed with an unmatchable
        // target. The settings UI also sanitises on input — this is the last line
        // of defence against a corrupted / hand-edited value.
        let normalizedCodeword = String(codeword.filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        let effectiveCodeword = normalizedCodeword.isEmpty ? Codewords.random() : normalizedCodeword
        if effectiveCodeword != codeword {
            DebugLog.log("startLock: codeword normalised (len \(codeword.count)→\(effectiveCodeword.count); stripped non-alphanumeric or empty-fallback)")
        }
        currentCodeword = effectiveCodeword
        matcher = CodewordMatcher(target: effectiveCodeword)
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
        sessionTrail = []
        pressedModifiers = []
        lastScrollAt = nil
        lastSwipeAt = nil
        lastPinchAt = nil
        lastRotateAt = nil
        lastSparkTriggerAt = 0
        // Reset cursor-jump detector state so the first mouseMoved of
        // the new session doesn't fire a false-positive jump relative
        // to wherever the cursor sat at the end of the last session.
        lastAutoSnapshotAt = 0
        mouseMovedSampleCount = 0
        lastAnyEventCursor = .zero
        lastAnyEventAt = 0
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
        soundPlayer.warmUp()
        installSpaceObserver()
        installScreenObserver()
        DebugLog.log("startLock: codewordLen=\(effectiveCodeword.count) durationMin=\(durationMinutes) tap=ok observer=ok")
        windowManager.show(
            controller: self,
            fixedBg: AppSettings.shared.backgroundSIMD,
            fixedPixel: AppSettings.shared.pixelSIMD,
            cellsPerAxis: AppSettings.shared.cellsPerAxis,
            stageThreshold: AppSettings.shared.stageAdvanceThreshold
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
        removeScreenObserver()
        soundPlayer.stop()
        recordSession()
        // Final cleanmap flush. Enqueue the latest snapshot on the serial save
        // queue (async): removeEventTap() above means no further keystrokes can
        // enqueue a save, so FIFO guarantees this snapshot writes last — without
        // blocking the event-tap callback this stopLock may be running inside
        // (the codeword-unlock path lands here from processKeyDown). The blocking
        // flush is reserved for applicationWillTerminate, which must hit disk
        // before the process exits.
        saveOverallKeyCountsAsync()
        wipesSinceLastCleanmapSave = 0
        PerfMetrics.shared.sessionStop()
        // Defer window teardown to the next run loop pass — calling window.close()
        // inside a CGEventTap callback (even via MainActor) leaves AppKit autorelease
        // pools un-drained and causes EXC_BAD_ACCESS when SwiftUI starts updating.
        PerfMetrics.shared.recordMainHop()
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

    /// Clear the current-session trailmap.
    func resetSessionTrailmap() {
        sessionTrail = []
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

    /// Blocking cleanmap flush for `applicationWillTerminate` only: the write
    /// must reach disk before the process exits. Runs on `.main` from the
    /// termination notification — NOT inside the event-tap callback — so the
    /// block is acceptable here (`stopLock` uses `saveOverallKeyCountsAsync` to
    /// stay off the unlock-keystroke path). Encodes on the caller, then runs the
    /// write on the SAME serial queue the throttled async saves use, blocking
    /// until it completes: the queue is FIFO, so any async save still in flight
    /// drains first and this final snapshot lands last — a late async write
    /// carrying an older snapshot can no longer regress the persisted counts.
    private func saveOverallKeyCounts() {
        let stringDict = Dictionary(uniqueKeysWithValues:
            overallKeyCounts.map { (String($0.key), $0.value) }
        )
        guard let data = try? JSONEncoder().encode(stringDict) else { return }
        PerfMetrics.shared.recordJSONEncode()
        Self.cleanmapSaveQueue.sync {
            UserDefaults.standard.set(data, forKey: Self.cleanmapKeyCountsKey)
        }
        PerfMetrics.shared.recordUserDefaultsWrite()
    }

    /// Hot-path variant of `saveOverallKeyCounts`. Snapshots the dictionary
    /// on the MainActor (cheap value-type copy of ~20-50 entries) and
    /// off-loads JSON encode + UserDefaults write to a serial utility
    /// queue. Apple guarantees `UserDefaults.set(_:forKey:)` is thread-
    /// safe. Also used for the FINAL flush in `stopLock`: FIFO ordering on the
    /// serial queue makes the last-enqueued snapshot win, and it keeps the
    /// unlock keystroke off the synchronous I/O path. The blocking
    /// `saveOverallKeyCounts` is reserved for `applicationWillTerminate`, where
    /// the write must reach disk before the process exits.
    private func saveOverallKeyCountsAsync() {
        let snapshot = overallKeyCounts
        let key = Self.cleanmapKeyCountsKey
        Self.cleanmapSaveQueue.async {
            let stringDict = Dictionary(uniqueKeysWithValues:
                snapshot.map { (String($0.key), $0.value) }
            )
            guard let data = try? JSONEncoder().encode(stringDict) else { return }
            UserDefaults.standard.set(data, forKey: key)
            Task { @MainActor in
                PerfMetrics.shared.recordJSONEncode()
                PerfMetrics.shared.recordUserDefaultsWrite()
            }
        }
    }


    // MARK: - Timer (pause-aware)

    private func startTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in LockController.shared.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        unlockTimer = timer
        startDisplayLink()
    }

    private func stopTimer() {
        unlockTimer?.invalidate()
        unlockTimer = nil
        stopDisplayLink()
    }

    /// Native-refresh-rate driver for the @Observable `displayTick`. Each
    /// fire bumps the tick, which propagates to subscribed views as a
    /// transaction for the same frame the system was already going to
    /// render — view body re-evals fit inside the rendering window
    /// instead of carving a separate MainActor preemption out of the
    /// next event-tap callback (which is what a 1 Hz `Timer.tick()`
    /// version did, surfacing as 5 ms key-callback p99 outliers).
    private func startDisplayLink() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            DebugLog.log("startDisplayLink: NSScreen.main nil and no screens — HUD tick disabled")
            return
        }
        let bridge = DisplayLinkBridge { [weak self] in
            self?.displayTick &+= 1
        }
        let link = screen.displayLink(target: bridge, selector: #selector(DisplayLinkBridge.fire))
        // Native refresh (60-120 Hz) on a busy MainActor (event-tap callbacks
        // + SwiftUI reconciliation) ate enough MainActor time to drop the
        // perf-test harness from its target 160 Hz combined event rate to
        // ~40 Hz, even though individual callback latencies stayed great.
        // 15 Hz is more than the eye needs for HUD counter readouts and
        // keeps the per-tick view-eval cost out of the event-tap path.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10,
                                                        maximum: 30,
                                                        preferred: 15)
        link.add(to: .main, forMode: .common)
        displayLinkBridge = bridge
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        displayLinkBridge = nil
    }

    private func tick() {
        // displayTick now bumps from CADisplayLink at the screen refresh
        // rate (see startDisplayLink) — this 1 Hz timer is just for
        // pause-detection + countdown, decoupled from view refresh.
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

    // MARK: - Screen arrangement observer

    /// Rebuild the lock surface when the display arrangement changes. Without
    /// this, a monitor hot-plugged mid-session has no lock window — leaving a
    /// usable desktop next to the lock — and the CADisplayLink stays anchored
    /// to the screen that was `NSScreen.main` at lock start, so it can stall
    /// (freezing the HUD counter) when the primary display changes.
    private func installScreenObserver() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isLocked else { return }
                // Coalesce the burst of notifications a single arrangement
                // change emits; rebuild once, shortly after it settles.
                self.screenChangeWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isLocked else { return }
                    self.rebuildLockSurface()
                }
                self.screenChangeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            }
        }
    }

    private func removeScreenObserver() {
        screenChangeWork?.cancel()
        screenChangeWork = nil
        if let token = screenObserver {
            NotificationCenter.default.removeObserver(token)
        }
        screenObserver = nil
    }

    /// Re-create the lock windows for the current screen set and re-anchor the
    /// display link. The per-cell wipe progress resets (the renderers are
    /// rebuilt) — acceptable for the rare hot-plug event, and far simpler than
    /// migrating live Metal mask state across a window rebuild.
    private func rebuildLockSurface() {
        guard isLocked else { return }
        DebugLog.log("screen params changed — rebuilding lock surface for \(NSScreen.screens.count) screen(s)")
        windowManager.show(
            controller: self,
            fixedBg: AppSettings.shared.backgroundSIMD,
            fixedPixel: AppSettings.shared.pixelSIMD,
            cellsPerAxis: AppSettings.shared.cellsPerAxis,
            stageThreshold: AppSettings.shared.stageAdvanceThreshold
        )
        // Re-anchor the display link to the (possibly new) main screen.
        stopDisplayLink()
        startDisplayLink()
    }

    /// The event tap could not be re-enabled (almost always: Accessibility
    /// permission revoked while locked). Break out of the dead lock instead of
    /// trapping the user, and explain why. Dispatched off the tap callback so
    /// the modal alert and window teardown don't run inside the C callback.
    private func handleDeadTap() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLocked else { return }
            self.stopLock()
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

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
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
                    // keyboards) keep the bookkeeping consistent with
                    // the regular keyDown path: keystrokeCount AND the
                    // bucket counter both bump, only the wipe is
                    // skipped because we have no F-key projection.
                    let nxKeycode = (nsEvent.data1 >> 16) & 0xFFFF
                    if let fKeycode = Self.nxToFnKeycode[nxKeycode] {
                        recordWipingKeystroke(
                            keycode: fKeycode,
                            bucket: .media,
                            eventLabel: "mediaKey nx=\(nxKeycode)"
                        )
                    } else {
                        keystrokeCount += 1
                        mediaKeyCount += 1
                        lastInputAt = Date()
                        if AppSettings.shared.verbosePerfEnabled {
                            PerfMetrics.shared.recordEvent("mediaKey nx=\(nxKeycode) unmapped")
                        } else {
                            PerfMetrics.shared.recordEvent("mediaKey")
                        }
                        triggerInputFeedback()
                    }
                }
                return nil
            }
            // Any other NX_SYSDEFINED subtype (power key, mouse aux, sleep,
            // etc.) is passed through untouched. Under verbose perf, log the
            // subtype so a power-button press during a session is observable in
            // the snapshot — this is the spike for "can we catch the power
            // button". On Apple Silicon / T2 Macs the power button is wired to
            // the SMC and handled by powerd below the session event tap, so it
            // most likely never reaches here at all; an empty log on press
            // confirms interception is not possible at the app layer. See TODO.
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
            // ⌘⌥Esc force-quit escape hatch. KeebLock is a cleaning aid, not a
            // kiosk lock (see threat model) — the user must always keep a manual
            // way out if the codeword path ever wedges. We swallow every other
            // keyDown, which previously ate Escape too and silently disabled the
            // documented force-quit combo. Detect Escape (keycode 53) carrying
            // both Command and Option and pass the event through untouched so the
            // system's Force Quit handler fires. The flags on the keyDown event
            // itself carry the modifier state, so this works even though we
            // swallow the Cmd/Opt flagsChanged events. Not counted as a wipe —
            // the user is escaping, not cleaning.
            let escKeycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if escKeycode == 53 {
                let forceQuitMods: CGEventFlags = [.maskCommand, .maskAlternate]
                if event.flags.contains(forceQuitMods) {
                    DebugLog.log("keyDown: ⌘⌥Esc force-quit combo — passing through")
                    return Unmanaged.passUnretained(event)
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

    /// Unified cursor-jump detector. Called from every event path that
    /// carries a meaningful `event.location` (mouseMoved, keyDown, …),
    /// so a jump that lands BETWEEN keystrokes without an intervening
    /// mouseMoved (the live symptom we're chasing) is still caught.
    /// Auto-snapshots the surrounding event ring on detection, throttled
    /// to ~1/s so a settled-in jump can't fire dozens of redundant ones.
    ///
    /// Threshold: 500 px. The earlier 300 px tripped on legitimate user
    /// motion now that mouseMoved is passed through — bursts of motion
    /// arriving in the same callback tick can accumulate a 400+ px delta
    /// even at normal hand-speeds. 500 px is still well below any
    /// plausible OS-driven cursor warp (e.g. multi-monitor jump) but
    /// outside the envelope of single-frame mouseMoved batching.
    /// Auto-snapshot is gated on verbosePerfEnabled at the call site, so
    /// no overhead in normal use.
    private func checkAnyEventCursorJump(_ loc: CGPoint, eventLabel: String) {
        let now = Date().timeIntervalSinceReferenceDate
        defer {
            lastAnyEventCursor = loc
            lastAnyEventAt = now
        }
        guard lastAnyEventAt > 0 else { return }
        // Synthetic key vs synthetic mouseMoved events have unrelated
        // event.location values (each picks its own default), so the
        // perf-test harness produces 500+ px deltas every few events
        // even though no real cursor warp happened. Auto-snapshots
        // inside that test would inject ~100 ms of disk I/O per fire
        // and break the latency measurement we're trying to take.
        #if DEBUG
        if PerfTestRunner.isRunning { return }
        #endif
        let dx = loc.x - lastAnyEventCursor.x
        let dy = loc.y - lastAnyEventCursor.y
        let dist = (dx * dx + dy * dy).squareRoot()
        guard dist > 500 else { return }
        guard now - lastAutoSnapshotAt > 0.5 else { return }
        let dt = now - lastAnyEventAt
        let fromX = Int(lastAnyEventCursor.x)
        let fromY = Int(lastAnyEventCursor.y)
        let toX = Int(loc.x)
        let toY = Int(loc.y)
        PerfMetrics.shared.recordEvent(
            "*** CURSOR JUMP via=\(eventLabel) from=(\(fromX),\(fromY)) to=(\(toX),\(toY)) Δ=\(Int(dist))px in \(Int(dt*1000))ms"
        )
        DebugLog.log("cursor jump: via \(eventLabel) from=(\(fromX),\(fromY)) to=(\(toX),\(toY)) Δ=\(Int(dist))px in \(Int(dt*1000))ms — auto snapshot")
        triggerInlineSnapshot()
        lastAutoSnapshotAt = now
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
        if AppSettings.shared.effectEnabled {
            let now = Date().timeIntervalSinceReferenceDate
            if now - lastSparkTriggerAt >= Self.sparkTriggerMinInterval {
                lastSparkTriggerAt = now
                sparkTrigger &+= 1
            }
        }
    }

    /// Bucket the keystroke counts in the breakdown. Each event path
    /// (regular keyDown, flagsChanged for modifiers, NX_SYSDEFINED
    /// for media keys) classifies once and routes through
    /// `recordWipingKeystroke` so the bookkeeping stays in sync.
    private enum KeyBucket {
        case function, control, letter, number, symbol, media
    }

    /// Single source of truth for "this physical key event counts as a
    /// wipe": bumps the counters, records the perf event, appends to
    /// the trail, throttle-saves the cleanmap, dispatches the wipe to
    /// the renderers, and fires audio/spark feedback.
    private func recordWipingKeystroke(keycode: UInt16,
                                       bucket: KeyBucket,
                                       eventLabel: String = "key",
                                       suppressFeedback: Bool = false) {
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
        dispatchWipe(for: keycode)
        if suppressFeedback {
            // Audio/sparks skipped (final unlock keystroke), but the
            // pause detector still needs to see the input.
            lastInputAt = now
        } else {
            triggerInputFeedback()
        }
    }

    private func processKeyDown(chars: String, keycode: UInt16) {
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

#if DEBUG
extension LockController {
    /// Direct-injection test path used by PerfTestHarness mode A. Calls
    /// handleEvent on the same MainActor a real tap callback would, so
    /// the result is identical apart from skipping the OS tap roundtrip.
    /// fileprivate-scoped handleEvent is reachable from this extension
    /// because it sits in the same source file.
    @MainActor
    func _testInjectEvent(_ event: CGEvent, type: CGEventType) {
        let t0 = PerfMetrics.now()
        _ = handleEvent(type: type, event: event)
        PerfMetrics.shared.recordCallback(machTicks: PerfMetrics.now() &- t0, type: type)
    }
}
#endif
