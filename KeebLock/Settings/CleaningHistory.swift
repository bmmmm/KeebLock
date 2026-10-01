import Combine
import Foundation

struct CleaningSession: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let durationSeconds: Int
    let keystrokeCount: Int
    let stageCount: Int

    init(
        id: UUID = UUID(),
        startedAt: Date,
        durationSeconds: Int,
        keystrokeCount: Int,
        stageCount: Int = 1
    ) {
        self.id = id
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.keystrokeCount = keystrokeCount
        self.stageCount = stageCount
    }

    // Older persisted records used to include a `codeword` field. JSONDecoder
    // ignores unknown keys by default, so old data still loads — the next
    // save() drops the field for good. No explicit migration required.

    var durationString: String {
        let m = durationSeconds / 60
        let s = durationSeconds % 60
        if m == 0 { return "\(s)s" }
        return "\(m)m \(s)s"
    }
}

final class CleaningHistory: ObservableObject {
    static let shared = CleaningHistory()

    @Published private(set) var sessions: [CleaningSession] = []

    private let defaults: UserDefaults
    private let storageKey = "cleaningHistory"
    private let maxKeep = 100

    /// `defaults` is injectable so tests can exercise the corrupt-blob
    /// recovery path against a throwaway `UserDefaults(suiteName:)` instance
    /// instead of polluting `.standard`. Production keeps the singleton.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
        // One-time migration: re-encode and overwrite so any legacy `codeword`
        // field still embedded in the persisted JSON blob is dropped on disk
        // (not just at decode time). Cheap (one JSON encode, max 100 records),
        // no-op when nothing's stored.
        if !sessions.isEmpty {
            save()
        }
    }

    /// Insert a finished session at the front (most-recent first).
    func record(_ session: CleaningSession) {
        sessions.insert(session, at: 0)
        if sessions.count > maxKeep {
            sessions = Array(sessions.prefix(maxKeep))
        }
        save()
    }

    func clear() {
        sessions = []
        save()
    }

    var lastWipe: Date? { sessions.first?.startedAt }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            sessions = try JSONDecoder().decode([CleaningSession].self, from: data)
        } catch {
            // Schema-incompatible blob. Silently overwriting on the next
            // save() destroys any chance of recovery — archive the bad
            // bytes under a single fixed key so a future migration (or a
            // user-supplied script) can salvage them, then start fresh.
            // Overwriting the same key keeps at most one archive, so a
            // repeatedly-failing load can't bloat the prefs plist.
            let archiveKey = "\(storageKey).corrupt"
            defaults.set(data, forKey: archiveKey)
            defaults.removeObject(forKey: storageKey)
            DebugLog.log("CleaningHistory: decode failed (\(error.localizedDescription)) — archived bad blob to \(archiveKey), starting fresh")
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
