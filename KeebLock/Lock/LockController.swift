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
    @Published private(set) var leftClickCount: Int = 0
    @Published private(set) var rightClickCount: Int = 0
    @Published private(set) var fnKeyCount: Int = 0
    @Published private(set) var codewordMatchProgress: Int = 0

    var missClickCount: Int { leftClickCount + rightClickCount + fnKeyCount }
    var soundDiagnostic: String { soundPlayer.engineStatus + " · \(String(format: "%.1f", soundPlayer.engineLatencyMs)) ms latency · \(soundPlayer.engineSampleRate) Hz · async dispatch" }

    private static let fnKeycodes: Set<UInt16> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var matcher = CodewordMatcher(target: "")
    private var unlockTimer: Timer?
    private var lastKeystrokeAt: Date?

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
        leftClickCount = 0
        rightClickCount = 0
        fnKeyCount = 0
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

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        if type == .leftMouseDown {
            leftClickCount += 1
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
            return nil
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

    private func processKeyDown(chars: String, keycode: UInt16) {
        keystrokeCount += 1
        lastKeystrokeAt = Date()

        if Self.fnKeycodes.contains(keycode) { fnKeyCount += 1 }

        if AppSettings.shared.soundEnabled { soundPlayer.play() }

        keyCounts[keycode, default: 0] += 1
        windowManager.wipeOnAllScreens()

        if AppSettings.shared.effectEnabled {
            sparkTrigger += 1
        }

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
