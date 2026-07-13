import Combine
import simd
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Lock

    @Published var codeword: String {
        didSet { defaults.set(codeword, forKey: Keys.codeword) }
    }

    @Published var durationMinutes: Int {
        didSet { defaults.set(durationMinutes, forKey: Keys.duration) }
    }

    /// Off by default. Force-quit (⌘⌥Esc) is always the safety net.
    @Published var autoUnlockEnabled: Bool {
        didSet { defaults.set(autoUnlockEnabled, forKey: Keys.autoUnlock) }
    }

    // MARK: - Appearance

    /// App-wide accent theme; tints all SwiftUI views via `.tint(...)`.
    @Published var appTheme: AppTheme {
        didSet { defaults.set(appTheme.rawValue, forKey: Keys.appTheme) }
    }

    // MARK: - Visuals

    /// 1 (chunky pixels, fast) ... 10 (small pixels, slow).
    @Published var pixelFineness: Int {
        didSet { defaults.set(pixelFineness, forKey: Keys.pixelFineness) }
    }

    var cellsPerAxis: Int { 4 * (pixelFineness + 1) }   // 1→8, 9→40, 10→44

    /// What's shown where the mask is "intact" (not yet wiped).
    /// Default: random per stage.
    @Published var backgroundColor: ColorPreset {
        didSet { defaults.set(backgroundColor.rawValue, forKey: Keys.bgColor) }
    }

    /// What's revealed when a cell gets wiped. Default: transparent (desktop visible).
    /// Setting this to a color and bg to transparent gives the "invert / dirty" mode.
    @Published var pixelColor: ColorPreset {
        didSet { defaults.set(pixelColor.rawValue, forKey: Keys.pixelColor) }
    }

    var backgroundSIMD: SIMD4<Float>? { backgroundColor.simd }
    var pixelSIMD: SIMD4<Float>? { pixelColor.simd }

    /// Quick toggle: swap the background and pixel choices.
    func swapColors() {
        let tmp = backgroundColor
        backgroundColor = pixelColor
        pixelColor = tmp
    }

    // MARK: - Effect

    @Published var effectEnabled: Bool {
        didSet { defaults.set(effectEnabled, forKey: Keys.sparks) }
    }

    @Published var sparkCount: Int {
        didSet { defaults.set(sparkCount, forKey: Keys.sparkCount) }
    }

    @Published var screenEffect: ScreenEffect {
        didSet { defaults.set(screenEffect.rawValue, forKey: Keys.screenEffect) }
    }

    @Published var wipeMode: WipeMode {
        didSet { defaults.set(wipeMode.rawValue, forKey: Keys.wipeMode) }
    }

    /// Fraction of cells that must be wiped before the stage advances
    /// to a fresh blank canvas. 1.00 demands the whole grid; lower
    /// values let the stage advance even when some cells stay
    /// perpetually unreachable (positional mode + system-bound F-keys
    /// the OS swallows before our event tap sees them). Range
    /// 0.80…1.00, default 1.00.
    @Published var stageAdvanceThreshold: Double {
        didSet { defaults.set(stageAdvanceThreshold, forKey: Keys.stageAdvanceThreshold) }
    }

    // MARK: - Sound

    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.sound) }
    }

    @Published var soundVolume: Double {
        didSet { defaults.set(soundVolume, forKey: Keys.soundVolume) }
    }

    @Published var soundFileBookmark: Data? {
        didSet { defaults.set(soundFileBookmark, forKey: Keys.soundFileBookmark) }
    }

    @Published var soundFileDisplayName: String? {
        didSet { defaults.set(soundFileDisplayName, forKey: Keys.soundFileName) }
    }

    @Published var unlockChimeEnabled: Bool {
        didSet { defaults.set(unlockChimeEnabled, forKey: Keys.unlockChime) }
    }

    // MARK: - Knowledge

    @Published var showCodewordKnowledge: Bool {
        didSet { defaults.set(showCodewordKnowledge, forKey: Keys.knowledge) }
    }

    /// When on, the lock screen tints the typed-codeword characters green
    /// as the match progresses. Off keeps the codeword display white at all
    /// times — also stops `codewordMatchProgress` from being read in the
    /// HUD body, which avoids a SwiftUI re-render of the whole HUD on every
    /// matched keystroke. Users with sound stutter under sustained typing
    /// see relief here even though sound and matching themselves are
    /// untouched.
    @Published var showCodewordProgress: Bool {
        didSet { defaults.set(showCodewordProgress, forKey: Keys.codewordProgress) }
    }

    // MARK: - Debug

    /// Cap for `keeblock.log`. When the file exceeds this size the next
    /// write rotates it to `keeblock.log.old` (replacing any previous
    /// .old) and starts fresh. Range 1…100 MB; 5 MB covers weeks of
    /// typical use including verbose-perf traces.
    @Published var logFileMaxSizeMB: Int {
        didSet {
            defaults.set(logFileMaxSizeMB, forKey: Keys.logMaxSize)
            syncDebugLogConfig()
        }
    }

    @Published var debugLoggingEnabled: Bool {
        didSet {
            defaults.set(debugLoggingEnabled, forKey: Keys.debug)
            syncDebugLogConfig()
            // Master-toggle off resets all subordinate debug settings so the
            // hidden state can't outlive the visible toggle.
            if !debugLoggingEnabled {
                if verbosePerfEnabled { verbosePerfEnabled = false }
                if lockOverlayDebugLevel != .off { lockOverlayDebugLevel = .off }
            }
        }
    }

    /// Push the logger-relevant values into DebugLog's lock-protected
    /// mirror. DebugLog.log() / rotateIfNeeded() run on background queues
    /// (SoundPlayer's audioQueue, DebugLog's ioQueue), where reading this
    /// @MainActor class directly would be an isolation violation.
    private func syncDebugLogConfig() {
        DebugLog.syncConfig(enabled: debugLoggingEnabled, maxSizeMB: logFileMaxSizeMB)
    }

    /// Gates per-event latency sampling in PerfMetrics. Aggregate counters
    /// keep running regardless; this only enables the ring-buffer + p99 work.
    @Published var verbosePerfEnabled: Bool {
        didSet { defaults.set(verbosePerfEnabled, forKey: Keys.verbosePerf) }
    }

    /// Lock-screen border-strip live-debug HUD. Anything above .off also
    /// dims the spark/effect intensity in the lock window (so debug numbers
    /// stay readable).
    @Published var lockOverlayDebugLevel: LockOverlayDebugLevel {
        didSet { defaults.set(lockOverlayDebugLevel.rawValue, forKey: Keys.lockOverlayLevel) }
    }

    /// Effective particle-spawn count for the lock-screen effect. Reduced
    /// when the live-debug overlay is on so the animation doesn't jitter
    /// the readout. Used by SparkOverlayView in place of `sparkCount`.
    var effectiveSparkCount: Int {
        // 0 = the user explicitly set the slider to off; the overlay
        // damping's `max(1, …)` floors must not resurrect the effect.
        guard sparkCount > 0 else { return 0 }
        switch lockOverlayDebugLevel {
        case .off:      return sparkCount
        case .minimal:  return max(1, sparkCount * 2 / 3)
        case .standard: return max(1, sparkCount / 2)
        case .verbose:  return max(1, sparkCount / 4)
        }
    }

    // MARK: - Storage

    private let defaults: UserDefaults

    private enum Keys {
        static let codeword           = "codeword"
        static let duration           = "durationMinutes"
        static let autoUnlock         = "autoUnlockEnabled"
        static let sound              = "soundEnabled"
        static let soundVolume        = "soundVolume"
        static let soundFileBookmark  = "soundFileBookmark"
        static let soundFileName      = "soundFileDisplayName"
        static let unlockChime        = "unlockChimeEnabled"
        static let sparks             = "sparksEnabled"
        static let sparkCount         = "sparkCount"
        static let screenEffect       = "screenEffect"
        static let wipeMode           = "wipeMode"
        static let stageAdvanceThreshold = "stageAdvanceThreshold"
        static let pixelFineness      = "pixelFineness"
        static let bgColor            = "backgroundColorPreset"
        static let pixelColor         = "pixelColorPreset"
        static let knowledge          = "showCodewordKnowledge"
        static let codewordProgress   = "showCodewordProgress"
        static let debug              = "debugLoggingEnabled"
        static let logMaxSize         = "logFileMaxSizeMB"
        static let verbosePerf        = "verbosePerfEnabled"
        static let lockOverlayLevel   = "lockOverlayDebugLevel"
        static let appTheme           = "appTheme"
    }

    /// `defaults` is injectable so tests can exercise the clamping/migration
    /// logic below against a throwaway `UserDefaults(suiteName:)` instance
    /// instead of polluting `.standard`. Production keeps the singleton.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults

        let saved = d.string(forKey: Keys.codeword) ?? ""
        self.codeword = saved.isEmpty ? Codewords.random() : saved

        let dur = d.integer(forKey: Keys.duration)
        // Snap to the values the segmented duration picker offers — a
        // legacy or hand-edited value (e.g. 7) would otherwise render the
        // picker with no selection.
        self.durationMinutes = [3, 5, 10].contains(dur) ? dur : 5
        self.autoUnlockEnabled = d.object(forKey: Keys.autoUnlock) as? Bool ?? false

        self.soundEnabled = d.object(forKey: Keys.sound) as? Bool ?? true
        let sv = d.object(forKey: Keys.soundVolume) as? Double ?? 0.6
        // Clamp like every other numeric setting here; SoundPlayer.setVolume
        // clamps to the same 0…2.0 range, so a legacy/out-of-range persisted
        // value would otherwise leave the slider and the label disagreeing.
        self.soundVolume = (0.0...2.0).contains(sv) ? sv : 0.6
        self.soundFileBookmark    = d.data(forKey: Keys.soundFileBookmark)
        self.soundFileDisplayName = d.string(forKey: Keys.soundFileName)
        self.unlockChimeEnabled   = d.object(forKey: Keys.unlockChime) as? Bool ?? true

        self.effectEnabled = d.object(forKey: Keys.sparks) as? Bool ?? false
        let sc = d.object(forKey: Keys.sparkCount) as? Int
        self.sparkCount = (sc.map { (0...30).contains($0) ? $0 : 12 }) ?? 12

        let effectRaw = d.string(forKey: Keys.screenEffect) ?? ScreenEffect.sparks.rawValue
        self.screenEffect = ScreenEffect(rawValue: effectRaw) ?? .sparks

        let wipeModeRaw = d.string(forKey: Keys.wipeMode) ?? WipeMode.random.rawValue
        self.wipeMode = WipeMode(rawValue: wipeModeRaw) ?? .random

        let threshold = d.object(forKey: Keys.stageAdvanceThreshold) as? Double ?? 1.0
        self.stageAdvanceThreshold = (0.80...1.00).contains(threshold) ? threshold : 1.0

        let pf = d.integer(forKey: Keys.pixelFineness)
        self.pixelFineness = (1...10).contains(pf) ? pf : 9

        let bgRaw = d.string(forKey: Keys.bgColor) ?? ColorPreset.random.rawValue
        self.backgroundColor = ColorPreset(rawValue: bgRaw) ?? .random

        let pxRaw = d.string(forKey: Keys.pixelColor) ?? ColorPreset.random.rawValue
        self.pixelColor = ColorPreset(rawValue: pxRaw) ?? .random

        self.showCodewordKnowledge = d.object(forKey: Keys.knowledge)    as? Bool ?? true
        self.showCodewordProgress  = d.object(forKey: Keys.codewordProgress) as? Bool ?? true
        let mb = d.object(forKey: Keys.logMaxSize) as? Int ?? 5
        self.logFileMaxSizeMB = (1...100).contains(mb) ? mb : 5
        self.debugLoggingEnabled   = d.object(forKey: Keys.debug)        as? Bool ?? false
        self.verbosePerfEnabled    = d.object(forKey: Keys.verbosePerf)  as? Bool ?? false

        let overlayRaw = d.string(forKey: Keys.lockOverlayLevel) ?? LockOverlayDebugLevel.off.rawValue
        self.lockOverlayDebugLevel = LockOverlayDebugLevel(rawValue: overlayRaw) ?? .off

        let themeRaw = d.string(forKey: Keys.appTheme) ?? AppTheme.day.rawValue
        self.appTheme = AppTheme(rawValue: themeRaw) ?? .day

        // didSet observers don't fire during init — push the initial
        // logger config explicitly.
        syncDebugLogConfig()

        // Same reason: the freshly rolled random codeword above never hit its
        // didSet, so it was never persisted and the app re-rolled the unlock
        // word on every launch. Persist it once so it stays stable.
        if saved.isEmpty {
            defaults.set(codeword, forKey: Keys.codeword)
        }
    }
}
