import Combine
import simd
import SwiftUI

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var codeword: String {
        didSet { UserDefaults.standard.set(codeword, forKey: Keys.codeword) }
    }

    @Published var durationMinutes: Int {
        didSet { UserDefaults.standard.set(durationMinutes, forKey: Keys.duration) }
    }

    @Published var soundEnabled: Bool {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: Keys.sound) }
    }

    @Published var sparksEnabled: Bool {
        didSet { UserDefaults.standard.set(sparksEnabled, forKey: Keys.sparks) }
    }

    // 1 (big chunky pixels, fast) ... 10 (small pixels, slow)
    @Published var pixelFineness: Int {
        didSet { UserDefaults.standard.set(pixelFineness, forKey: Keys.pixelFineness) }
    }

    @Published var debugLoggingEnabled: Bool {
        didSet { UserDefaults.standard.set(debugLoggingEnabled, forKey: Keys.debug) }
    }

    // Mask cells along the X axis, derived from the slider.
    var cellsPerAxis: Int { 4 * (pixelFineness + 1) }   // 1→8, 5→24, 9→40, 10→44

    // [R, G, B] in 0–1 range. nil = random color per stage.
    @Published var customScreenColorRGB: [Double]? {
        didSet { UserDefaults.standard.set(customScreenColorRGB, forKey: Keys.screenColor) }
    }

    var customScreenSIMD: SIMD4<Float>? {
        guard let rgb = customScreenColorRGB, rgb.count == 3 else { return nil }
        return SIMD4<Float>(Float(rgb[0]), Float(rgb[1]), Float(rgb[2]), 1.0)
    }

    var customSwiftUIColor: Color {
        guard let rgb = customScreenColorRGB, rgb.count == 3 else { return .white }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    private enum Keys {
        static let codeword       = "codeword"
        static let duration       = "durationMinutes"
        static let sound          = "soundEnabled"
        static let sparks         = "sparksEnabled"
        static let pixelFineness  = "pixelFineness"
        static let screenColor    = "screenColorRGB"
        static let debug          = "debugLoggingEnabled"
    }

    private init() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Keys.codeword) ?? ""
        self.codeword = saved.isEmpty ? Codewords.random() : saved
        let dur = defaults.integer(forKey: Keys.duration)
        self.durationMinutes = dur > 0 ? dur : 5
        self.soundEnabled       = defaults.object(forKey: Keys.sound)   as? Bool ?? true
        self.sparksEnabled      = defaults.object(forKey: Keys.sparks)  as? Bool ?? true
        let pf = defaults.integer(forKey: Keys.pixelFineness)
        self.pixelFineness      = (1...10).contains(pf) ? pf : 9   // default 9 → 40 cells
        self.customScreenColorRGB = defaults.array(forKey: Keys.screenColor) as? [Double]
        self.debugLoggingEnabled  = defaults.object(forKey: Keys.debug) as? Bool ?? false
    }
}
