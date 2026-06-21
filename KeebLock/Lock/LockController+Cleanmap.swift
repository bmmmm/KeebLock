import AppKit

extension LockController {
    // MARK: - Cleanmap persistence

    /// Uralt UserDefaults key — single combined dictionary blob from the
    /// very first heatmap implementation. Folded into the current blob on
    /// first launch after that migration, then removed.
    static let legacyKeyCountsDefaultsKey = "heatmapKeyCounts"
    /// Previous current-blob key (pre-rename). Folded into
    /// `cleanmapKeyCountsKey` once on the upgrade that introduced the
    /// rename, then removed. Kept as a constant only for that migration.
    static let legacyHeatmapOverallKey = "heatmapOverallKeyCounts"
    /// Key for the persistent overall-cleanmap blob (post-rename).
    static let cleanmapKeyCountsKey = "cleanmapOverallKeyCounts"
    /// One-shot flag set after the uralt → overall fold. Without it, a
    /// downgrade-then-upgrade cycle (old build re-writes the legacy key,
    /// new build re-folds on next launch) silently double-counts.
    static let legacyMigrationDoneKey = "heatmapMigratedFromLegacy"
    /// One-shot flag set after the heatmap → cleanmap rename fold. Same
    /// downgrade-protection rationale as above.
    static let renameToCleanmapDoneKey = "renamedFromHeatmapToCleanmap"
    @ObservationIgnored static let cleanmapSaveStride: Int = 50
    /// Background queue for the throttled cleanmap save so the JSON encode
    /// and UserDefaults write never land inside an event-tap callback.
    /// Serial: ordering of saves matters (later snapshots must overwrite
    /// earlier ones, not race with them).
    @ObservationIgnored static let cleanmapSaveQueue = DispatchQueue(
        label: "de.6bm.KeebLock.cleanmap-save",
        qos: .utility
    )

    func loadOverallKeyCounts() {
        // Pick up the current blob first.
        if let data = UserDefaults.standard.data(forKey: Self.cleanmapKeyCountsKey),
           let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
            PerfMetrics.shared.recordJSONDecode()
            overallKeyCounts = Dictionary(uniqueKeysWithValues: dict.compactMap { key, val -> (UInt16, Int)? in
                guard let code = UInt16(key) else { return nil }
                return (code, val)
            })
        }
        // One-shot rename migration: pre-rename data lived under
        // `heatmapOverallKeyCounts`. Fold (additive) into the new key
        // and remove the old blob so a downgrade can't double-count
        // on a subsequent upgrade.
        if !UserDefaults.standard.bool(forKey: Self.renameToCleanmapDoneKey) {
            if let data = UserDefaults.standard.data(forKey: Self.legacyHeatmapOverallKey),
               let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
                PerfMetrics.shared.recordJSONDecode()
                for (key, val) in dict {
                    guard let code = UInt16(key) else { continue }
                    overallKeyCounts[code, default: 0] += val
                }
                UserDefaults.standard.removeObject(forKey: Self.legacyHeatmapOverallKey)
            }
            UserDefaults.standard.set(true, forKey: Self.renameToCleanmapDoneKey)
        }
        // Uralt one-shot migration: existing users had data under the
        // legacy single-blob key before the privacy-pass dropped
        // persistence. Now that overall persistence is back (per-user
        // request), fold whatever's still under the legacy key in and
        // remove it. Same one-shot flag protection.
        guard !UserDefaults.standard.bool(forKey: Self.legacyMigrationDoneKey) else { return }
        if let legacyData = UserDefaults.standard.data(forKey: Self.legacyKeyCountsDefaultsKey),
           let legacyDict = try? JSONDecoder().decode([String: Int].self, from: legacyData) {
            PerfMetrics.shared.recordJSONDecode()
            for (key, val) in legacyDict {
                guard let code = UInt16(key) else { continue }
                overallKeyCounts[code, default: 0] += val
            }
            UserDefaults.standard.removeObject(forKey: Self.legacyKeyCountsDefaultsKey)
        }
        UserDefaults.standard.set(true, forKey: Self.legacyMigrationDoneKey)
    }

    /// Blocking cleanmap flush for `applicationWillTerminate` only: the write
    /// must reach disk before the process exits. Runs on `.main` from the
    /// termination notification — NOT inside the event-tap callback — so the
    /// block is acceptable here (`stopLock` uses `saveOverallKeyCountsAsync` to
    /// stay off the unlock-keystroke path). Encodes on the caller, then runs the
    /// write on the SAME serial queue the throttled async saves use, blocking
    /// until it completes: the queue is FIFO, so any async save still in flight
    /// drains first and this final snapshot lands last — a late async write
    /// carrying an older snapshot can no longer regress the persisted counts.
    func saveOverallKeyCounts() {
        let stringDict = Dictionary(uniqueKeysWithValues:
            overallKeyCounts.map { (String($0.key), $0.value) }
        )
        guard let data = try? JSONEncoder().encode(stringDict) else { return }
        PerfMetrics.shared.recordJSONEncode()
        Self.cleanmapSaveQueue.sync {
            UserDefaults.standard.set(data, forKey: Self.cleanmapKeyCountsKey)
        }
        PerfMetrics.shared.recordUserDefaultsWrite()
    }

    /// Hot-path variant of `saveOverallKeyCounts`. Snapshots the dictionary
    /// on the MainActor (cheap value-type copy of ~20-50 entries) and
    /// off-loads JSON encode + UserDefaults write to a serial utility
    /// queue. Apple guarantees `UserDefaults.set(_:forKey:)` is thread-
    /// safe. Also used for the FINAL flush in `stopLock`: FIFO ordering on the
    /// serial queue makes the last-enqueued snapshot win, and it keeps the
    /// unlock keystroke off the synchronous I/O path. The blocking
    /// `saveOverallKeyCounts` is reserved for `applicationWillTerminate`, where
    /// the write must reach disk before the process exits.
    func saveOverallKeyCountsAsync() {
        let snapshot = overallKeyCounts
        let key = Self.cleanmapKeyCountsKey
        Self.cleanmapSaveQueue.async {
            let stringDict = Dictionary(uniqueKeysWithValues:
                snapshot.map { (String($0.key), $0.value) }
            )
            guard let data = try? JSONEncoder().encode(stringDict) else { return }
            UserDefaults.standard.set(data, forKey: key)
            Task { @MainActor in
                PerfMetrics.shared.recordJSONEncode()
                PerfMetrics.shared.recordUserDefaultsWrite()
            }
        }
    }
}
