import Combine
import simd
import SwiftUI

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Lock

    @Published var codeword: String {
        didSet { defaults.set(codeword, forKey: Keys.codeword) }
    }

    @Published var durationMinutes: Int {
        didSet { defaults.set(durationMinutes, forKey: Keys.duration) }
    }

    // MARK: - Visuals

    /// 1 (chunky pixels, fast) ... 10 (small pixels, slow). Drives mask resolution.
    @Published var pixelFineness: Int {
        didSet { defaults.set(pixelFineness, forKey: Keys.pixelFineness) }
    }

    /// Mask cells along the X axis. Y is derived from screen aspect.
    var cellsPerAxis: Int { 4 * (pixelFineness + 1) }   // 1→8, 9→40, 10→44

    /// nil = pick random color per stage. Otherwise locked.
    @Published var customScreenColorRGB: [Double]? {
        didSet { defaults.set(customScreenColorRGB, forKey: Keys.screenColor) }
    }

    var customScreenSIMD: SIMD4<Float>? {
        guard let rgb = customScreenColorRGB, rgb.count == 3 else { return nil }
        return SIMD4<Float>(Float(rgb[0]), Float(rgb[1]), Float(rgb[2]), 1.0)
    }

    var customSwiftUIColor: Color {
        guard let rgb = customScreenColorRGB, rgb.count == 3 else { return .white }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    // MARK: - Sparks

    @Published var sparksEnabled: Bool {
        didSet { defaults.set(sparksEnabled, forKey: Keys.sparks) }
    }

    /// 0 = no sparks even if enabled, 30 = max splash.
    @Published var sparkCount: Int {
        didSet { defaults.set(sparkCount, forKey: Keys.sparkCount) }
    }

    // MARK: - Sound

    @Published var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.sound) }
    }

    /// 0.0 ... 1.0
    @Published var soundVolume: Double {
        didSet { defaults.set(soundVolume, forKey: Keys.soundVolume) }
    }

    /// Security-scoped bookmark to a user-picked audio file. nil = use synth click.
    @Published var soundFileBookmark: Data? {
        didSet { defaults.set(soundFileBookmark, forKey: Keys.soundFileBookmark) }
    }

    /// Display name of the picked audio file (cached for UI).
    @Published var soundFileDisplayName: String? {
        didSet { defaults.set(soundFileDisplayName, forKey: Keys.soundFileName) }
    }

    // MARK: - Debug

    @Published var debugLoggingEnabled: Bool {
        didSet { defaults.set(debugLoggingEnabled, forKey: Keys.debug) }
    }

    // MARK: - Storage

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let codeword           = "codeword"
        static let duration           = "durationMinutes"
        static let sound              = "soundEnabled"
        static let soundVolume        = "soundVolume"
        static let soundFileBookmark  = "soundFileBookmark"
        static let soundFileName      = "soundFileDisplayName"
        static let sparks             = "sparksEnabled"
        static let sparkCount         = "sparkCount"
        static let pixelFineness      = "pixelFineness"
        static let screenColor        = "screenColorRGB"
        static let debug              = "debugLoggingEnabled"
    }

    private init() {
        let d = UserDefaults.standard

        let saved = d.string(forKey: Keys.codeword) ?? ""
        self.codeword = saved.isEmpty ? Codewords.random() : saved

        let dur = d.integer(forKey: Keys.duration)
        self.durationMinutes = dur > 0 ? dur : 5

        self.soundEnabled = d.object(forKey: Keys.sound) as? Bool ?? true
        self.soundVolume  = d.object(forKey: Keys.soundVolume) as? Double ?? 0.6
        self.soundFileBookmark    = d.data(forKey: Keys.soundFileBookmark)
        self.soundFileDisplayName = d.string(forKey: Keys.soundFileName)

        self.sparksEnabled = d.object(forKey: Keys.sparks) as? Bool ?? true
        let sc = d.object(forKey: Keys.sparkCount) as? Int
        self.sparkCount = (sc.map { (0...30).contains($0) ? $0 : 12 }) ?? 12

        let pf = d.integer(forKey: Keys.pixelFineness)
        self.pixelFineness = (1...10).contains(pf) ? pf : 9   // default 9 → 40 cells

        self.customScreenColorRGB = d.array(forKey: Keys.screenColor) as? [Double]

        self.debugLoggingEnabled = d.object(forKey: Keys.debug) as? Bool ?? false
    }
}
