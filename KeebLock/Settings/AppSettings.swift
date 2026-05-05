import Combine
import simd
import SwiftUI

// MARK: - Screen effect type

enum ScreenEffect: String, CaseIterable, Identifiable, Codable {
    case sparks, rain, matrix, bubbles, snow

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sparks:  return "Sparks"
        case .rain:    return "Rain"
        case .matrix:  return "Matrix"
        case .bubbles: return "Bubbles"
        case .snow:    return "Snow"
        }
    }

    var icon: String {
        switch self {
        case .sparks:  return "sparkles"
        case .rain:    return "cloud.rain.fill"
        case .matrix:  return "chevron.down.square.fill"
        case .bubbles: return "bubbles.and.sparkles"
        case .snow:    return "snowflake"
        }
    }

    var activeColor: Color {
        switch self {
        case .sparks:  return Color(red: 0.73, green: 0.60, blue: 0.98)
        case .rain:    return Color(red: 0.25, green: 0.55, blue: 0.95)
        case .matrix:  return Color(red: 0.05, green: 0.75, blue: 0.25)
        case .bubbles: return Color(red: 0.30, green: 0.80, blue: 1.00)
        case .snow:    return Color(red: 0.60, green: 0.80, blue: 1.00)
        }
    }
}

// MARK: - Color presets

/// Predefined color choices for both the background and the cleaning pixel layers.
/// `.random` = renderer picks a fresh hue per stage. `.transparent` = alpha 0
/// (desktop visible). All other cases are opaque pastel presets.
enum ColorPreset: String, CaseIterable, Identifiable, Codable {
    case random
    case transparent
    case rose
    case lavender
    case mint
    case sky
    case peach
    case lemon
    case coral
    case lilac

    var id: String { rawValue }
    var label: String {
        switch self {
        case .random: return "Random"
        case .transparent: return "Transparent"
        default: return rawValue.capitalized
        }
    }

    /// nil = let renderer roll a random color per stage.
    var rgba: [Double]? {
        switch self {
        case .random:      return nil
        case .transparent: return [0, 0, 0, 0]
        case .rose:        return [1.00, 0.71, 0.76, 1.0]
        case .lavender:    return [0.73, 0.60, 0.98, 1.0]
        case .mint:        return [0.62, 0.96, 0.78, 1.0]
        case .sky:         return [0.60, 0.85, 1.00, 1.0]
        case .peach:       return [1.00, 0.78, 0.60, 1.0]
        case .lemon:       return [1.00, 0.96, 0.52, 1.0]
        case .coral:       return [1.00, 0.60, 0.60, 1.0]
        case .lilac:       return [0.82, 0.65, 1.00, 1.0]
        }
    }

    var simd: SIMD4<Float>? {
        guard let c = rgba else { return nil }
        return SIMD4<Float>(Float(c[0]), Float(c[1]), Float(c[2]), Float(c[3]))
    }

    var swiftUIColor: Color {
        guard let c = rgba else { return .accentColor }   // placeholder for .random
        return Color(red: c[0], green: c[1], blue: c[2]).opacity(c[3])
    }
}

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

    // MARK: - Knowledge

    @Published var showCodewordKnowledge: Bool {
        didSet { defaults.set(showCodewordKnowledge, forKey: Keys.knowledge) }
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
        static let autoUnlock         = "autoUnlockEnabled"
        static let sound              = "soundEnabled"
        static let soundVolume        = "soundVolume"
        static let soundFileBookmark  = "soundFileBookmark"
        static let soundFileName      = "soundFileDisplayName"
        static let sparks             = "sparksEnabled"
        static let sparkCount         = "sparkCount"
        static let screenEffect       = "screenEffect"
        static let pixelFineness      = "pixelFineness"
        static let bgColor            = "backgroundColorPreset"
        static let pixelColor         = "pixelColorPreset"
        static let knowledge          = "showCodewordKnowledge"
        static let debug              = "debugLoggingEnabled"
    }

    private init() {
        let d = UserDefaults.standard

        let saved = d.string(forKey: Keys.codeword) ?? ""
        self.codeword = saved.isEmpty ? Codewords.random() : saved

        let dur = d.integer(forKey: Keys.duration)
        self.durationMinutes = dur > 0 ? dur : 5
        self.autoUnlockEnabled = d.object(forKey: Keys.autoUnlock) as? Bool ?? false

        self.soundEnabled = d.object(forKey: Keys.sound) as? Bool ?? true
        self.soundVolume  = d.object(forKey: Keys.soundVolume) as? Double ?? 0.6
        self.soundFileBookmark    = d.data(forKey: Keys.soundFileBookmark)
        self.soundFileDisplayName = d.string(forKey: Keys.soundFileName)

        self.effectEnabled = d.object(forKey: Keys.sparks) as? Bool ?? true
        let sc = d.object(forKey: Keys.sparkCount) as? Int
        self.sparkCount = (sc.map { (0...30).contains($0) ? $0 : 12 }) ?? 12

        let effectRaw = d.string(forKey: Keys.screenEffect) ?? ScreenEffect.sparks.rawValue
        self.screenEffect = ScreenEffect(rawValue: effectRaw) ?? .sparks

        let pf = d.integer(forKey: Keys.pixelFineness)
        self.pixelFineness = (1...10).contains(pf) ? pf : 9

        let bgRaw = d.string(forKey: Keys.bgColor) ?? ColorPreset.random.rawValue
        self.backgroundColor = ColorPreset(rawValue: bgRaw) ?? .random

        let pxRaw = d.string(forKey: Keys.pixelColor) ?? ColorPreset.transparent.rawValue
        self.pixelColor = ColorPreset(rawValue: pxRaw) ?? .transparent

        self.showCodewordKnowledge = d.object(forKey: Keys.knowledge) as? Bool ?? true
        self.debugLoggingEnabled   = d.object(forKey: Keys.debug)     as? Bool ?? false
    }
}
