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

    var isLocked: Bool = false
    var remainingSeconds: Int = 0
    var totalSeconds: Int = 0
    var currentCodeword: String = ""
    var isPaused: Bool = false

    /// Low-rate pulse driven by a CADisplayLink throttled to 10–30 Hz
    /// (see startDisplayLink). Views that display per-event counters
    /// subscribe to this instead of to the counters themselves — the
    /// counters live as @ObservationIgnored so the per-keystroke /
    /// per-mousedown mutations don't fire view-update cascades through
    /// the registrar. Mirrors PerfMetrics.tickSeq.
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
    var displayTick: Int = 0

    /// Bumped by the reset functions below. The cleanmap / trailmap stores
    /// (`sessionKeyCounts`, `overallKeyCounts`, `sessionTrail`) are
    /// @ObservationIgnored for hot-path reasons, so clearing them fires no
    /// observation event — without this tracked pulse the Cleanmap /
    /// Trailmap sheets would keep showing the old data after a Reset click
    /// until something else happened to invalidate them.
    var statsResetPulse: Int = 0

    /// Per-keycode counts for the *current* lock session. Reset on each
    /// startLock(). Lives in memory only.
    @ObservationIgnored var sessionKeyCounts: [UInt16: Int] = [:]
    /// Per-keycode counts accumulated across every lock session on this
    /// machine. Persisted to UserDefaults on each stopLock and re-loaded
    /// on launch. The user can clear it via the Cleanmap view's Reset
    /// button. Privacy-trade-off acknowledged: this is keystroke-pattern
    /// data and stays on-disk, scoped to this user's UserDefaults — never
    /// leaves the machine.
    @ObservationIgnored var overallKeyCounts: [UInt16: Int] = [:]
    /// Ordered sequence of (keycode, timestamp) pairs for the *current*
    /// lock session — drives the Trailmap view's polyline rendering.
    /// Reset on each startLock(). Lives in memory only; not persisted
    /// (the cross-session view was deemed not useful enough to justify
    /// the on-disk footprint).
    @ObservationIgnored var sessionTrail: [TrailPoint] = []
    /// Timestamp of the first wipe in the current trail. `sessionTrail` is
    /// ring-trimmed at trailMaxPoints, so `trail.first` is not the session
    /// start once a session exceeds the cap — this survives the trim so the
    /// Trailmap can show the true duration. Reset with the trail.
    @ObservationIgnored var sessionTrailStartedAt: TimeInterval?
    @ObservationIgnored var keystrokeCount: Int = 0
    var sparkTrigger: Int = 0
    // Keyboard breakdown — all @ObservationIgnored: per-keyDown bumps were
    // multiplying the per-event publish count under the hot path. Views
    // refresh on displayTick.
    @ObservationIgnored var letterCount: Int = 0
    @ObservationIgnored var numberCount: Int = 0
    /// Punctuation, !@#$%&, all printable non-letter / non-number chars.
    @ObservationIgnored var symbolCount: Int = 0
    /// Esc, Tab, Return, Space, Backspace, Delete, Arrows, Home/End/PgUp/PgDn.
    @ObservationIgnored var controlKeyCount: Int = 0
    /// F1–F20.
    @ObservationIgnored var functionKeyCount: Int = 0
    /// Brightness, Volume, Play/Next/Prev — emitted by NX_SYSDEFINED subtype 8.
    @ObservationIgnored var mediaKeyCount: Int = 0
    // Mouse breakdown — also off the observation path. Same rationale.
    @ObservationIgnored var leftClickCount: Int = 0
    @ObservationIgnored var rightClickCount: Int = 0
    @ObservationIgnored var middleClickCount: Int = 0
    @ObservationIgnored var backClickCount: Int = 0
    @ObservationIgnored var forwardClickCount: Int = 0
    @ObservationIgnored var scrollCount: Int = 0
    // Gestures
    /// Discrete 3/4-finger trackpad swipes — counts both NSEventType.swipe
    /// (31) when the tap sees it AND `activeSpaceDidChange` notifications
    /// (which is how 4-finger swipes manifest on macOS 26+ where the OS
    /// dispatches the gesture above our event tap). Debounced across both
    /// paths so a swipe that triggers a Space change counts once, not twice.
    @ObservationIgnored var swipeCount: Int = 0
    /// 2-finger pinch (NSEventType.magnify = 30) plus double-tap zoom
    /// (NSEventType.smartMagnify = 32). Magnify streams during a pinch, so
    /// debounced; smartMagnify is discrete and counted directly.
    @ObservationIgnored var pinchCount: Int = 0
    /// 2-finger rotation attempts. NSEventType.rotate = 18, debounced.
    @ObservationIgnored var rotateCount: Int = 0

    var codewordMatchProgress: Int = 0

    /// Bumps each time the in-lock "snapshot" button (rendered by
    /// LockOverlayDebug at the top-right) is clicked. The overlay
    /// watches this for changes to flash a "SAVED" toast — the actual
    /// snapshot write happens synchronously in triggerInlineSnapshot().
    var snapshotPulse: Int = 0

    /// Monotonically increasing counter; HUDView modulos by `currentEntry.facts.count`
    /// to pick which fact to show. Lives here (not per-HUDView) so multi-monitor
    /// users see the same fact on every screen instead of each window
    /// independently rolling its own.
    var factRotationTick: Int = 0
    @ObservationIgnored var lastFactRotationKeystroke: Int = 0
    static let factRotationStride = 30

    var soundDiagnostic: String { soundPlayer.engineStatus + " · \(String(format: "%.1f", soundPlayer.engineLatencyMs)) ms latency · \(soundPlayer.engineSampleRate) Hz" }

    var eventTapInstalled: Bool { eventTap != nil }
    var spaceObserverInstalled: Bool { spaceObserver != nil }
    var lockWindowCount: Int { windowManager.windowCount }
    /// Per-screen wipe-renderer state for diagnostic snapshots; empty
    /// when no lock is active.
    var screenWipeStates: [WipeRenderer.State] { windowManager.screenStates() }

    // @ObservationIgnored: these are internal state, never read from a
    // SwiftUI body. Without the annotation, mutating them through the
    // event-tap callback would still post observation tracking events
    // even though no view reads them — pure cost, no benefit.
    @ObservationIgnored var eventTap: CFMachPort?
    @ObservationIgnored var runLoopSource: CFRunLoopSource?
    @ObservationIgnored var matcher = CodewordMatcher(target: "")
    @ObservationIgnored var unlockTimer: Timer?
    /// Drives the displayTick at the screen's native refresh rate so view
    /// re-evals batch into frames the system was already going to render —
    /// no separate MainActor preemption window like a Timer would create.
    @ObservationIgnored var displayLink: CADisplayLink?
    @ObservationIgnored var displayLinkBridge: DisplayLinkBridge?
    @ObservationIgnored var lastInputAt: Date?
    /// Modifier keycodes currently held. flagsChanged fires once on
    /// press and once on release for the same keycode; tracking the
    /// set lets us count press only.
    @ObservationIgnored var pressedModifiers: Set<UInt16> = []
    @ObservationIgnored var lastScrollAt: Date?
    @ObservationIgnored var lastSwipeAt: Date?
    @ObservationIgnored var lastPinchAt: Date?
    @ObservationIgnored var lastRotateAt: Date?
    @ObservationIgnored var spaceObserver: NSObjectProtocol?
    /// Watches for display arrangement changes (monitor hot-plug/unplug,
    /// resolution or primary-display change) so we can rebuild the lock
    /// surface across the new screen set while locked.
    @ObservationIgnored var screenObserver: NSObjectProtocol?
    /// Coalesces the burst of `didChangeScreenParameters` notifications a
    /// single hot-plug emits into one rebuild.
    @ObservationIgnored var screenChangeWork: DispatchWorkItem?
    /// Cursor location at the most recent keyDown, captured from
    /// `CGEvent.location`. Used purely by the verbose-perf event-ring
    /// log so we can see if the cursor jumps between two consecutive
    /// keystrokes during a burst — the "Mauszeiger springt nach
    /// schnellem Tippen" symptom we're chasing.
    @ObservationIgnored var lastKeyDownCursor: CGPoint = .zero
    /// Counter to sample 1-in-N mouseMoved events into the verbose-perf
    /// event ring. Without sampling, mouseMoved at 60-120 Hz would push
    /// every keyDown out of the 80-entry ring within a second.
    @ObservationIgnored var mouseMovedSampleCount: Int = 0
    /// Cursor position from the most recent mouseMoved/dragged event,
    /// used by the auto-snapshot jump detector. Different from
    /// `lastKeyDownCursor` because we want to track every mouse update,
    /// not just keystroke samples.
    /// Throttle for the auto-snapshot trigger. Without it a single jump
    /// can fire dozens of snapshots as the cursor settles into its new
    /// position — we only want one per discrete jump event.
    @ObservationIgnored var lastAutoSnapshotAt: TimeInterval = 0
    /// Unified cursor tracker across ALL events (keyDown, mouseMoved,
    /// clicks). The original mouseMoved-only tracker missed jumps that
    /// happen between consecutive keystrokes without an intervening
    /// mouseMoved — which is exactly the live symptom we're chasing.
    /// `event.location` is set on every CGEvent regardless of type, so
    /// this fires on whichever event-type arrives next.
    @ObservationIgnored var lastAnyEventCursor: CGPoint = .zero
    @ObservationIgnored var lastAnyEventAt: TimeInterval = 0

    /// 60 Hz gate on sparkTrigger increments. The visual effect already
    /// rate-limits spawn() inside SparkOverlayView to 60 Hz, but the
    /// upstream sparkTrigger mutation drives a LockView → SparkOverlayView
    /// body re-eval *per keystroke* — capping the bump at 60 Hz collapses
    /// that cascade for autorepeat / perf-test bursts without altering
    /// the visible effect (normal typing stays well under 60 Hz).
    @ObservationIgnored var lastSparkTriggerAt: TimeInterval = 0
    static let sparkTriggerMinInterval: TimeInterval = 1.0 / 60.0

    @ObservationIgnored let pauseDetectThreshold: TimeInterval = 30
    /// Window after lockStartedAt during which non-keyboard events are still
    /// swallowed by the tap but not counted/sounded/sparked. Eats the burst
    /// from `windowManager.show()` activating the lock window — Magic Mouse
    /// emits a `.gesture` stream the moment the cursor crosses the new
    /// window, and `activeSpaceDidChange` may fire from the AppKit promotion
    /// itself. 0.7 s is the longest of those bursts I've measured.
    @ObservationIgnored let warmupGracePeriod: TimeInterval = 0.7
    @ObservationIgnored let windowManager = LockWindowManager()
    @ObservationIgnored let soundPlayer = SoundPlayer()

    /// Uralt UserDefaults key — single combined dictionary blob from the
    /// very first heatmap implementation. Folded into the current blob on
    /// first launch after that migration, then removed.
    static let legacyKeyCountsDefaultsKey = "heatmapKeyCounts"
    /// Previous current-blob key (pre-rename). Folded into
    /// `cleanmapKeyCountsKey` once on the upgrade that introduced the
    /// rename, then removed. Kept as a constant only for that migration.
    static let legacyHeatmapOverallKey = "heatmapOverallKeyCounts"
    /// Key for the persistent overall-cleanmap blob (post-rename).
    static let cleanmapKeyCountsKey = "cleanmapOverallKeyCounts"
    /// One-shot flag set after the uralt → overall fold. Without it, a
    /// downgrade-then-upgrade cycle (old build re-writes the legacy key,
    /// new build re-folds on next launch) silently double-counts.
    static let legacyMigrationDoneKey = "heatmapMigratedFromLegacy"
    /// One-shot flag set after the heatmap → cleanmap rename fold. Same
    /// downgrade-protection rationale as above.
    static let renameToCleanmapDoneKey = "renamedFromHeatmapToCleanmap"
    /// FIFO cap for the session trail. 5 000 wipes is roughly 15-20
    /// minutes of brisk typing, well past the visual density at which
    /// the polyline becomes unreadable. Memory cost is
    /// `count * (UInt16 + Double)` — about 50 KB at the cap.
    static let trailMaxPoints = 5000

    @ObservationIgnored var lockStartedAt: Date?
    /// Set synchronously at the top of `stopLock()` so a re-entry from a
    /// different code path (e.g. timer auto-unlock firing between codeword
    /// match and the deferred `isLocked = false`) doesn't run the teardown
    /// sequence twice — which would otherwise double-play the unlock chime
    /// and double-record the session.
    @ObservationIgnored var isStopping: Bool = false
    /// Counter for the throttled overall-cleanmap save during an active
    /// session. Incremented per wipe; flushed every Nth or on
    /// `applicationWillTerminate`. Without periodic flush a crash mid-
    /// session loses every wipe accumulated since the last
    /// `stopLock()` save.
    @ObservationIgnored var wipesSinceLastCleanmapSave: Int = 0
    @ObservationIgnored static let cleanmapSaveStride: Int = 50
    /// Background queue for the throttled cleanmap save so the JSON encode
    /// and UserDefaults write never land inside an event-tap callback.
    /// Serial: ordering of saves matters (later snapshots must overwrite
    /// earlier ones, not race with them).
    @ObservationIgnored static let cleanmapSaveQueue = DispatchQueue(
        label: "de.6bm.KeebLock.cleanmap-save",
        qos: .utility
    )
    @ObservationIgnored var bag = Set<AnyCancellable>()

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
        sessionTrailStartedAt = nil
        // Seed from the modifiers physically held at lock-start. A modifier
        // held while clicking Lock (then released mid-session) would otherwise
        // arrive as a lone flagsChanged that the empty set mis-pairs as a press
        // — a phantom wipe plus inverted press/release parity for the rest of
        // the session. keyState is keycode-exact, so left/right are tracked
        // independently. Caps lock (57) is a toggle handled separately; exclude it.
        pressedModifiers = Set(Self.modifierKeycodes.filter { keycode in
            keycode != 57 && CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keycode))
        })
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
        statsResetPulse &+= 1
    }

    /// Clear the persistent overall cleanmap and the on-disk blob.
    func resetOverallCleanmap() {
        overallKeyCounts = [:]
        UserDefaults.standard.removeObject(forKey: Self.cleanmapKeyCountsKey)
        statsResetPulse &+= 1
    }

    /// Clear the current-session trailmap.
    func resetSessionTrailmap() {
        sessionTrail = []
        sessionTrailStartedAt = nil
        statsResetPulse &+= 1
    }

    // MARK: - Timer (pause-aware)

    private func startTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
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
    var isInWarmup: Bool {
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
            stageThreshold: AppSettings.shared.stageAdvanceThreshold,
            rebuild: true
        )
        // Re-anchor the display link to the (possibly new) main screen.
        stopDisplayLink()
        startDisplayLink()
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
    func isInsideInlineSnapshotRegion(_ point: CGPoint) -> Bool {
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
    func triggerInlineSnapshot() {
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
    func saveOverallKeyCountsAsync() {
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
    func checkAnyEventCursorJump(_ loc: CGPoint, eventLabel: String) {
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
    func triggerInputFeedback(now: Date = Date()) {
        lastInputAt = now
        if AppSettings.shared.soundEnabled { soundPlayer.play() }
        if AppSettings.shared.effectEnabled {
            let nowRef = now.timeIntervalSinceReferenceDate
            if nowRef - lastSparkTriggerAt >= Self.sparkTriggerMinInterval {
                lastSparkTriggerAt = nowRef
                sparkTrigger &+= 1
            }
        }
    }

}

#if DEBUG
extension LockController {
    /// Direct-injection test path used by PerfTestHarness mode A. Calls
    /// handleEvent on the same MainActor a real tap callback would, so
    /// the result is identical apart from skipping the OS tap roundtrip.
    @MainActor
    func _testInjectEvent(_ event: CGEvent, type: CGEventType) {
        let t0 = PerfMetrics.now()
        _ = handleEvent(type: type, event: event)
        PerfMetrics.shared.recordCallback(machTicks: PerfMetrics.now() &- t0, type: type)
    }
}
#endif
