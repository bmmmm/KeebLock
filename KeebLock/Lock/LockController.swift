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
    @Published private(set) var mediaKeyCount: Int = 0
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

    @Published private(set) var codewordMatchProgress: Int = 0

    /// Everything the user pressed that did NOT contribute to codeword progress.
    var missClickCount: Int {
        otherKeyCount + fnKeyCount + mediaKeyCount
            + leftClickCount + rightClickCount + middleClickCount
            + backClickCount + forwardClickCount + scrollCount
            + spaceSwitchCount
    }
    var soundDiagnostic: String { soundPlayer.engineStatus + " · \(String(format: "%.1f", soundPlayer.engineLatencyMs)) ms latency · \(soundPlayer.engineSampleRate) Hz · async dispatch" }

    private static let fnKeycodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var matcher = CodewordMatcher(target: "")
    private var unlockTimer: Timer?
    private var lastKeystrokeAt: Date?
    private var lastScrollAt: Date?
    private var spaceObserver: NSObjectProtocol?

    private let pauseDetectThreshold: TimeInterval = 30
    private let windowManager = LockWindowManager()
    private let soundPlayer = SoundPlayer()

    private static let keyCountsDefaultsKey = "heatmapKeyCounts"

    private var lockStartedAt: Date?
    private var bag = Set<AnyCancellable>()

    private init() {
        loadKeyCounts()
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
        mediaKeyCount = 0
        otherKeyCount = 0
        leftClickCount = 0
        rightClickCount = 0
        middleClickCount = 0
        backClickCount = 0
        forwardClickCount = 0
        scrollCount = 0
        spaceSwitchCount = 0
        lastScrollAt = nil
        codewordMatchProgress = 0
        totalSeconds = max(60, durationMinutes * 60)
        remainingSeconds = totalSeconds
        lastKeystrokeAt = Date()
        isPaused = false
        lockStartedAt = Date()

        guard installEventTap() else {
            DebugLog.log("startLock: installEventTap returned false (accessibility?)")
            return
        }
        installSpaceObserver()
        DebugLog.log("startLock: codewordLen=\(codeword.count) durationMin=\(durationMinutes)")
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
        DebugLog.log("stopLock: keystrokes=\(keystrokeCount) remaining=\(remainingSeconds)s")
        stopTimer()
        removeEventTap()
        removeSpaceObserver()
        soundPlayer.stop()
        saveKeyCounts()
        recordSession()
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
            codeword: currentCodeword,
            stageCount: windowManager.maxStage
        )
        CleaningHistory.shared.record(session)
        lockStartedAt = nil
    }

    func resetKeyCounts() {
        keyCounts = [:]
        UserDefaults.standard.removeObject(forKey: Self.keyCountsDefaultsKey)
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

    // MARK: - Persistence

    private func loadKeyCounts() {
        guard let data = UserDefaults.standard.data(forKey: Self.keyCountsDefaultsKey),
              let dict = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        keyCounts = Dictionary(uniqueKeysWithValues: dict.compactMap { key, val -> (UInt16, Int)? in
            guard let code = UInt16(key) else { return nil }
            return (code, val)
        })
    }

    private func saveKeyCounts() {
        let stringDict = Dictionary(uniqueKeysWithValues: keyCounts.map { (String($0.key), $0.value) })
        if let data = try? JSONEncoder().encode(stringDict) {
            UserDefaults.standard.set(data, forKey: Self.keyCountsDefaultsKey)
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
                              // NOTE: trackpad gesture/swipe events (NSEventType 29/31)
                              // intentionally NOT tapped. Type 29 conflicts with 2-finger
                              // scroll; type 31 doesn't fire for 4-finger between-spaces
                              // swipes anyway. The screensaver-level lock window keeps the
                              // user on the current Space without needing to swallow the
                              // gesture, and activeSpaceDidChangeNotification catches any
                              // edge case where a switch does slip through.
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return MainActor.assumeIsolated {
                    let controller = Unmanaged<LockController>.fromOpaque(refcon).takeUnretainedValue()
                    return controller.handleEvent(type: type, event: event)
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
            self.triggerMissClickFeedback()
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
            triggerMissClickFeedback()
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
            triggerMissClickFeedback()
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
            triggerMissClickFeedback()
            return nil
        }
        if type == .scrollWheel {
            // Trackpad/Magic-Mouse scrolls fire ~60 events/sec — debounce so a single
            // gesture maps to ~1 count + one feedback burst, not a machine-gun.
            let now = Date()
            if lastScrollAt == nil || now.timeIntervalSince(lastScrollAt!) > 0.25 {
                scrollCount += 1
                triggerMissClickFeedback()
            }
            lastScrollAt = now
            return nil
        }

        if type.rawValue == 14 {
            // NX_SYSDEFINED: subtype 8 = aux control buttons (brightness, volume,
            // mission control, spotlight, media keys on Fn-layer). Other subtypes
            // (power button, mouse aux buttons) pass through untouched.
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
                    triggerMissClickFeedback()
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

    /// Audio + visual feedback fired on every blocked input (keystroke, mouse,
    /// fn/media key). Pixel wipe is intentionally NOT here — it stays exclusive
    /// to keyDown so misclicks don't grant free cleaning progress.
    private func triggerMissClickFeedback() {
        if AppSettings.shared.soundEnabled { soundPlayer.play() }
        if AppSettings.shared.effectEnabled { sparkTrigger += 1 }
    }

    private func processKeyDown(chars: String, keycode: UInt16) {
        keystrokeCount += 1
        lastKeystrokeAt = Date()

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
        windowManager.wipeOnAllScreens()
        triggerMissClickFeedback()

        for ch in chars where ch.isLetter || ch.isNumber {
            if matcher.feed(ch) {
                stopLock()
                return
            }
        }
        let progress = matcher.matchProgress
        if progress != codewordMatchProgress { codewordMatchProgress = progress }
    }
}
