import Combine
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

    private enum Keys {
        static let codeword = "codeword"
        static let duration = "durationMinutes"
        static let sound = "soundEnabled"
    }

    private init() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Keys.codeword) ?? ""
        self.codeword = saved.isEmpty ? Codewords.random() : saved
        let dur = defaults.integer(forKey: Keys.duration)
        self.durationMinutes = dur > 0 ? dur : 5
        self.soundEnabled = defaults.object(forKey: Keys.sound) as? Bool ?? true
    }
}
