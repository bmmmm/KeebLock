import Combine
import Foundation

struct CleaningSession: Codable, Identifiable {
    let id: UUID
    let startedAt: Date
    let durationSeconds: Int
    let keystrokeCount: Int
    let codeword: String
    let stageCount: Int

    init(
        id: UUID = UUID(),
        startedAt: Date,
        durationSeconds: Int,
        keystrokeCount: Int,
        codeword: String,
        stageCount: Int = 1
    ) {
        self.id = id
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.keystrokeCount = keystrokeCount
        self.codeword = codeword
        self.stageCount = stageCount
    }

    var dateString: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: startedAt)
    }

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

    private let storageKey = "cleaningHistory"
    private let maxKeep = 100

    private init() { load() }

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
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        if let decoded = try? JSONDecoder().decode([CleaningSession].self, from: data) {
            sessions = decoded
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}
