import Foundation
import Testing
@testable import KeebLock

struct CleaningHistoryTests {

    /// Same throwaway-suite pattern as AppSettingsTests: unique name per
    /// invocation, persistent domain removed afterwards.
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "de.6bm.KeebLock.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
    }

    private func makeSession(keystrokes: Int = 10) -> CleaningSession {
        CleaningSession(
            startedAt: Date(timeIntervalSince1970: 1_000_000),
            durationSeconds: 90,
            keystrokeCount: keystrokes
        )
    }

    // MARK: - Corrupt-blob recovery

    @Test func corruptBlobIsArchivedAndStorageCleared() {
        withDefaults { d in
            let garbage = Data("this is not json".utf8)
            d.set(garbage, forKey: "cleaningHistory")

            let history = CleaningHistory(defaults: d)

            #expect(history.sessions.isEmpty)
            #expect(d.data(forKey: "cleaningHistory.corrupt") == garbage)
            #expect(d.data(forKey: "cleaningHistory") == nil)
        }
    }

    @Test func corruptArchiveIsOverwrittenNotAccumulated() {
        withDefaults { d in
            d.set(Data("first bad blob".utf8), forKey: "cleaningHistory.corrupt")
            let garbage = Data("second bad blob".utf8)
            d.set(garbage, forKey: "cleaningHistory")

            _ = CleaningHistory(defaults: d)

            #expect(d.data(forKey: "cleaningHistory.corrupt") == garbage)
        }
    }

    // MARK: - Load / save roundtrip

    @Test func recordedSessionsSurviveReload() {
        withDefaults { d in
            let first = CleaningHistory(defaults: d)
            first.record(makeSession(keystrokes: 42))

            let second = CleaningHistory(defaults: d)
            #expect(second.sessions.count == 1)
            #expect(second.sessions.first?.keystrokeCount == 42)
        }
    }

    @Test func emptyDefaultsYieldEmptyHistory() {
        withDefaults { d in
            let history = CleaningHistory(defaults: d)
            #expect(history.sessions.isEmpty)
            #expect(history.lastWipe == nil)
            // No sessions -> no migration re-save; storage stays untouched.
            #expect(d.data(forKey: "cleaningHistory") == nil)
        }
    }

    // MARK: - Legacy codeword field migration

    @Test func legacyCodewordFieldIsDroppedFromDiskOnInit() {
        withDefaults { d in
            let legacyJSON = """
            [{"id":"00000000-0000-0000-0000-000000000001",\
            "startedAt":700000000,\
            "codeword":"legacy-secret",\
            "durationSeconds":60,\
            "keystrokeCount":42,\
            "stageCount":2}]
            """
            d.set(Data(legacyJSON.utf8), forKey: "cleaningHistory")

            let history = CleaningHistory(defaults: d)

            // Decodes despite the unknown key...
            #expect(history.sessions.count == 1)
            #expect(history.sessions.first?.keystrokeCount == 42)
            #expect(history.sessions.first?.stageCount == 2)

            // ...and the one-time re-save scrubbed it from disk.
            let persisted = d.data(forKey: "cleaningHistory").map { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(!persisted.isEmpty)
            #expect(!persisted.contains("legacy-secret"))
            #expect(!persisted.contains("codeword"))
        }
    }

    // MARK: - record / clear

    @Test func recordInsertsMostRecentFirst() {
        withDefaults { d in
            let history = CleaningHistory(defaults: d)
            history.record(makeSession(keystrokes: 1))
            history.record(makeSession(keystrokes: 2))
            #expect(history.sessions.first?.keystrokeCount == 2)
            #expect(history.sessions.last?.keystrokeCount == 1)
        }
    }

    @Test func recordCapsAtOneHundredSessions() {
        withDefaults { d in
            let history = CleaningHistory(defaults: d)
            for i in 1...101 {
                history.record(makeSession(keystrokes: i))
            }
            #expect(history.sessions.count == 100)
            // Newest kept, oldest (keystrokes == 1) dropped.
            #expect(history.sessions.first?.keystrokeCount == 101)
            #expect(history.sessions.last?.keystrokeCount == 2)
        }
    }

    @Test func clearEmptiesAndPersists() {
        withDefaults { d in
            let history = CleaningHistory(defaults: d)
            history.record(makeSession())
            history.clear()
            #expect(history.sessions.isEmpty)

            let reloaded = CleaningHistory(defaults: d)
            #expect(reloaded.sessions.isEmpty)
        }
    }

    @Test func lastWipeReturnsMostRecentStart() {
        withDefaults { d in
            let history = CleaningHistory(defaults: d)
            let newest = Date(timeIntervalSince1970: 2_000_000)
            history.record(CleaningSession(startedAt: Date(timeIntervalSince1970: 1_000_000), durationSeconds: 60, keystrokeCount: 1))
            history.record(CleaningSession(startedAt: newest, durationSeconds: 60, keystrokeCount: 1))
            #expect(history.lastWipe == newest)
        }
    }
}
