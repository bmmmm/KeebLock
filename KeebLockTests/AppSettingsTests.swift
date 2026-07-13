import Foundation
import Testing
@testable import KeebLock

@MainActor
struct AppSettingsTests {

    /// Runs `body` against a throwaway UserDefaults suite. Suite names are
    /// unique per invocation so parallel tests never share state; the
    /// persistent domain is removed afterwards so repeat runs start clean
    /// (`UserDefaults(suiteName:)` writes a real plist to disk).
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "de.6bm.KeebLock.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    // MARK: - durationMinutes

    @Test func durationSnapsLegacyValueToDefault() {
        withDefaults { d in
            d.set(7, forKey: "durationMinutes")
            #expect(AppSettings(defaults: d).durationMinutes == 5)
        }
    }

    @Test func durationKeepsValidValue() {
        withDefaults { d in
            d.set(10, forKey: "durationMinutes")
            #expect(AppSettings(defaults: d).durationMinutes == 10)
        }
    }

    @Test func durationDefaultsWhenUnset() {
        withDefaults { d in
            #expect(AppSettings(defaults: d).durationMinutes == 5)
        }
    }

    // MARK: - soundVolume

    @Test func soundVolumeRejectsAboveRange() {
        withDefaults { d in
            d.set(5.0, forKey: "soundVolume")
            #expect(AppSettings(defaults: d).soundVolume == 0.6)
        }
    }

    @Test func soundVolumeRejectsNegative() {
        withDefaults { d in
            d.set(-1.0, forKey: "soundVolume")
            #expect(AppSettings(defaults: d).soundVolume == 0.6)
        }
    }

    @Test func soundVolumeKeepsValidValue() {
        withDefaults { d in
            d.set(1.5, forKey: "soundVolume")
            #expect(AppSettings(defaults: d).soundVolume == 1.5)
        }
    }

    @Test func soundVolumeKeepsUpperBound() {
        withDefaults { d in
            d.set(2.0, forKey: "soundVolume")
            #expect(AppSettings(defaults: d).soundVolume == 2.0)
        }
    }

    // MARK: - sparkCount

    @Test func sparkCountRejectsAboveRange() {
        withDefaults { d in
            d.set(99, forKey: "sparkCount")
            #expect(AppSettings(defaults: d).sparkCount == 12)
        }
    }

    @Test func sparkCountRejectsNegative() {
        withDefaults { d in
            d.set(-1, forKey: "sparkCount")
            #expect(AppSettings(defaults: d).sparkCount == 12)
        }
    }

    @Test func sparkCountKeepsExplicitZero() {
        withDefaults { d in
            d.set(0, forKey: "sparkCount")
            #expect(AppSettings(defaults: d).sparkCount == 0)
        }
    }

    @Test func sparkCountDefaultsWhenUnset() {
        withDefaults { d in
            #expect(AppSettings(defaults: d).sparkCount == 12)
        }
    }

    // MARK: - pixelFineness

    @Test func pixelFinenessRejectsAboveRange() {
        withDefaults { d in
            d.set(11, forKey: "pixelFineness")
            #expect(AppSettings(defaults: d).pixelFineness == 9)
        }
    }

    @Test func pixelFinenessRejectsZero() {
        // Also the unset case: integer(forKey:) yields 0 for a missing key,
        // which the 1...10 check maps to the default.
        withDefaults { d in
            d.set(0, forKey: "pixelFineness")
            #expect(AppSettings(defaults: d).pixelFineness == 9)
        }
    }

    @Test func pixelFinenessKeepsValidValue() {
        withDefaults { d in
            d.set(1, forKey: "pixelFineness")
            #expect(AppSettings(defaults: d).pixelFineness == 1)
        }
    }

    // MARK: - logFileMaxSizeMB

    @Test func logFileMaxSizeRejectsAboveRange() {
        withDefaults { d in
            d.set(500, forKey: "logFileMaxSizeMB")
            #expect(AppSettings(defaults: d).logFileMaxSizeMB == 5)
        }
    }

    @Test func logFileMaxSizeRejectsZero() {
        withDefaults { d in
            d.set(0, forKey: "logFileMaxSizeMB")
            #expect(AppSettings(defaults: d).logFileMaxSizeMB == 5)
        }
    }

    @Test func logFileMaxSizeKeepsValidValue() {
        withDefaults { d in
            d.set(100, forKey: "logFileMaxSizeMB")
            #expect(AppSettings(defaults: d).logFileMaxSizeMB == 100)
        }
    }

    // MARK: - stageAdvanceThreshold

    @Test func stageAdvanceThresholdRejectsBelowRange() {
        withDefaults { d in
            d.set(0.5, forKey: "stageAdvanceThreshold")
            #expect(AppSettings(defaults: d).stageAdvanceThreshold == 1.0)
        }
    }

    @Test func stageAdvanceThresholdRejectsAboveRange() {
        withDefaults { d in
            d.set(1.5, forKey: "stageAdvanceThreshold")
            #expect(AppSettings(defaults: d).stageAdvanceThreshold == 1.0)
        }
    }

    @Test func stageAdvanceThresholdKeepsLowerBound() {
        withDefaults { d in
            d.set(0.80, forKey: "stageAdvanceThreshold")
            #expect(AppSettings(defaults: d).stageAdvanceThreshold == 0.80)
        }
    }

    @Test func stageAdvanceThresholdDefaultsWhenUnset() {
        withDefaults { d in
            #expect(AppSettings(defaults: d).stageAdvanceThreshold == 1.0)
        }
    }

    // MARK: - enum rawValue fallbacks

    @Test func screenEffectFallsBackOnUnknownRawValue() {
        withDefaults { d in
            d.set("not-a-real-effect", forKey: "screenEffect")
            #expect(AppSettings(defaults: d).screenEffect == .sparks)
        }
    }

    @Test func screenEffectKeepsKnownRawValue() {
        withDefaults { d in
            d.set("matrix", forKey: "screenEffect")
            #expect(AppSettings(defaults: d).screenEffect == .matrix)
        }
    }

    @Test func wipeModeFallsBackOnUnknownRawValue() {
        withDefaults { d in
            d.set("not-a-real-mode", forKey: "wipeMode")
            #expect(AppSettings(defaults: d).wipeMode == .random)
        }
    }

    @Test func backgroundColorFallsBackOnUnknownRawValue() {
        withDefaults { d in
            d.set("not-a-real-color", forKey: "backgroundColorPreset")
            #expect(AppSettings(defaults: d).backgroundColor == .random)
        }
    }

    @Test func pixelColorFallsBackOnUnknownRawValue() {
        withDefaults { d in
            d.set("not-a-real-color", forKey: "pixelColorPreset")
            #expect(AppSettings(defaults: d).pixelColor == .random)
        }
    }

    @Test func lockOverlayDebugLevelFallsBackOnUnknownRawValue() {
        withDefaults { d in
            d.set("not-a-real-level", forKey: "lockOverlayDebugLevel")
            #expect(AppSettings(defaults: d).lockOverlayDebugLevel == .off)
        }
    }

    @Test func appThemeFallsBackOnUnknownRawValue() {
        withDefaults { d in
            d.set("not-a-real-theme", forKey: "appTheme")
            #expect(AppSettings(defaults: d).appTheme == .day)
        }
    }

    // MARK: - codeword first-launch persistence

    @Test func freshCodewordIsRolledAndPersisted() {
        withDefaults { d in
            let settings = AppSettings(defaults: d)
            #expect(!settings.codeword.isEmpty)
            #expect(d.string(forKey: "codeword") == settings.codeword)
        }
    }

    @Test func existingCodewordIsKept() {
        withDefaults { d in
            d.set("existingword", forKey: "codeword")
            #expect(AppSettings(defaults: d).codeword == "existingword")
        }
    }

    // MARK: - hasSeenIntro

    @Test func hasSeenIntroDefaultsToFalse() {
        withDefaults { d in
            #expect(AppSettings(defaults: d).hasSeenIntro == false)
        }
    }

    @Test func hasSeenIntroPersistsOnceSet() {
        withDefaults { d in
            let settings = AppSettings(defaults: d)
            settings.hasSeenIntro = true
            #expect(d.bool(forKey: "hasSeenIntro") == true)
            #expect(AppSettings(defaults: d).hasSeenIntro == true)
        }
    }
}
