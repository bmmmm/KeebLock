import Combine
import Darwin
import Foundation

// Lightweight in-process telemetry for the lock loop. Counters are bumped from
// hot paths (event-tap callback, wipe scheduler, JSON I/O) and surfaced via
// the Settings → Debug panel and DebugLog snapshots. All public state is
// MainActor-isolated to match the project default; hot-path bumps are cheap
// integer mutations on the same actor that drives the event tap callback.
//
// Toggle: AppSettings.shared.verbosePerfEnabled gates the per-event work
// (callback latency sampling + ring buffer). Aggregate counters always run
// because each is a single Int += that costs less than reading the toggle.
@MainActor
final class PerfMetrics: ObservableObject {
    static let shared = PerfMetrics()

    /// Bumps once per 1 Hz rate-timer tick (and on sessionStart/Stop) so
    /// SwiftUI views observing PerfMetrics refresh at 1 Hz instead of
    /// per-event. Every other field is a plain `var` — they're read
    /// on-demand from inside body(), but their MUTATIONS no longer fire
    /// objectWillChange publishes. Pre-this-change, recordCallback was
    /// publishing 3 times per event (Avg/Max/Samples) directly from the
    /// CGEventTap callback; when LockOverlayDebug or DebugInfoPanel
    /// happened to be in the middle of a body() evaluation, the publish
    /// landed *during* a view update and SwiftUI logged "Publishing
    /// changes from within view updates is not allowed, this will cause
    /// undefined behavior." × dozens, plus made the event-tap latency
    /// max balloon to ~18 ms because the callback was racing the view
    /// update phase. 1 Hz refresh on the readouts is more than enough.
    @Published private(set) var tickSeq: Int = 0

    // MARK: - Event-tap callback latency (ns) — plain, refreshed at 1 Hz
    private(set) var eventCallbackMaxNs: UInt64 = 0
    private(set) var eventCallbackAvgNs: UInt64 = 0
    private(set) var eventCallbackP99Ns: UInt64 = 0
    private(set) var eventCallbackSamples: Int = 0

    // MARK: - Per-second rates (sliding 1 s bucket)
    private(set) var eventTapEventsPerSec: Int = 0
    private(set) var wipeCallsPerSec: Int = 0
    private(set) var mainHopsPerSec: Int = 0

    // MARK: - Allocation / I/O counters (cumulative across session)
    private(set) var nsEventAllocations: Int = 0
    private(set) var jsonEncodeCount: Int = 0
    private(set) var jsonDecodeCount: Int = 0
    private(set) var userDefaultsWrites: Int = 0
    /// Number of times macOS posted `tapDisabledByTimeout` against our
    /// event tap during this session. This is the smoking gun for the
    /// cursor-flicker symptom: when the callback misses its budget,
    /// macOS briefly disables the tap, so the cursor (which we normally
    /// swallow via mouseMoved) becomes reactive for a frame or two.
    /// Non-zero values here mean the lock loop blew its time budget.
    private(set) var tapTimeoutCount: Int = 0
    /// Cumulative wipe count across the session, distinct from
    /// `wipeBucket` (which is a sliding 1-second bucket reset on each
    /// rate-timer tick). Bumped from `recordWipe()` so it survives the
    /// tick reset and gives the perf-test snapshot a stable total.
    private(set) var wipesTotal: Int = 0

    // MARK: - Memory
    private(set) var memoryStartMB: Double = 0
    private(set) var memoryNowMB: Double = 0
    var memoryDeltaMB: Double { memoryNowMB - memoryStartMB }

    // MARK: - Internal sampling state

    private var latencyRing: [UInt64] = []
    private let latencyRingCapacity = 1024
    private var latencyRingHead = 0
    /// Cumulative ns over the session, used to derive eventCallbackAvgNs as
    /// `total / samples`. Replaces an earlier Welford-style streaming
    /// average — that one used `&+` / `&-` on UInt64, so any sample below
    /// the running mean wrapped the diff into the 10^19 range and yielded
    /// avg readings of ~5 days. Cumulative-sum overflow only matters above
    /// 5×10^14 ns of total latency (~5 days at 1 µs/sample); a lock session
    /// won't get there.
    private var eventCallbackTotalNs: UInt64 = 0

    private var eventBucket = 0
    private var wipeBucket = 0
    private var mainHopBucket = 0

    private var rateTimer: Timer?

    /// Chronological ring of the last N events handled by the lock loop.
    /// Useful for spotting bursts / hangs — the per-second rates show a
    /// moving average, but a ring of timestamped tags shows whether 80
    /// of the 105 events landed in a single 50 ms window. Only filled
    /// when verbose-perf is on; zero cost otherwise.
    private var eventRing: [String] = []
    private let eventRingCapacity = 80
    private var eventRingHead = 0
    private var sessionStartTicks: UInt64 = 0

    // mach_absolute_time → ns conversion factor (1 on x86, 125/3 on Apple silicon).
    private static let machTimebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private init() {}

    // MARK: - Lifecycle

    /// Begin a measurement window for the current lock session.
    func sessionStart() {
        reset()
        memoryStartMB = Self.currentResidentMB()
        memoryNowMB = memoryStartMB
        sessionStartTicks = mach_absolute_time()
        startRateTimer()
        tickSeq &+= 1
    }

    func sessionStop() {
        stopRateTimer()
        memoryNowMB = Self.currentResidentMB()
        tickSeq &+= 1
    }

    /// Discard all samples; called at session start so figures shown in
    /// Settings always reflect the current run.
    func reset() {
        eventCallbackMaxNs = 0
        eventCallbackAvgNs = 0
        eventCallbackP99Ns = 0
        eventCallbackSamples = 0
        eventCallbackTotalNs = 0
        latencyRing.removeAll(keepingCapacity: true)
        latencyRingHead = 0

        eventTapEventsPerSec = 0
        wipeCallsPerSec = 0
        mainHopsPerSec = 0
        eventBucket = 0
        wipeBucket = 0
        mainHopBucket = 0

        nsEventAllocations = 0
        jsonEncodeCount = 0
        jsonDecodeCount = 0
        userDefaultsWrites = 0
        tapTimeoutCount = 0
        wipesTotal = 0

        eventRing.removeAll(keepingCapacity: true)
        eventRingHead = 0
    }

    /// Append a one-line tag for the current event to the ring buffer.
    /// Includes elapsed-ms relative to session start so timing patterns
    /// are visible at a glance in the snapshot. Cheap when verbose-perf
    /// is off (single bool check + return).
    func recordEvent(_ tag: String) {
        guard AppSettings.shared.verbosePerfEnabled else { return }
        let elapsedMs = Self.ticksToNs(mach_absolute_time() &- sessionStartTicks) / 1_000_000
        let line = "+\(elapsedMs)ms \(tag)"
        if eventRing.count < eventRingCapacity {
            eventRing.append(line)
        } else {
            eventRing[eventRingHead] = line
            eventRingHead = (eventRingHead &+ 1) % eventRingCapacity
        }
    }

    /// Chronologically-ordered copy of the ring (oldest first). Used by
    /// DebugLog.snapshot to tail the recent activity into the report.
    func eventLines() -> [String] {
        guard !eventRing.isEmpty else { return [] }
        if eventRing.count < eventRingCapacity {
            return eventRing
        }
        let tail = Array(eventRing[eventRingHead...])
        let head = Array(eventRing[..<eventRingHead])
        return tail + head
    }

    // MARK: - Recording (cheap, called from hot paths)

    func recordCallback(machTicks: UInt64) {
        eventBucket &+= 1
        guard AppSettings.shared.verbosePerfEnabled else { return }
        let ns = Self.ticksToNs(machTicks)
        eventCallbackSamples &+= 1
        if ns > eventCallbackMaxNs { eventCallbackMaxNs = ns }
        eventCallbackTotalNs &+= ns
        eventCallbackAvgNs = eventCallbackTotalNs / UInt64(eventCallbackSamples)
        if latencyRing.count < latencyRingCapacity {
            latencyRing.append(ns)
        } else {
            latencyRing[latencyRingHead] = ns
            latencyRingHead = (latencyRingHead &+ 1) % latencyRingCapacity
        }
    }

    func recordWipe()              { wipeBucket &+= 1; wipesTotal &+= 1 }
    func recordMainHop()           { mainHopBucket &+= 1 }
    func recordNSEventAlloc()      { nsEventAllocations &+= 1 }
    func recordJSONEncode()        { jsonEncodeCount &+= 1 }
    func recordJSONDecode()        { jsonDecodeCount &+= 1 }
    func recordUserDefaultsWrite() { userDefaultsWrites &+= 1 }
    func recordTapTimeout()        { tapTimeoutCount &+= 1 }

    // MARK: - Mach timing helpers

    /// Snapshot the high-resolution monotonic clock; subtract two snapshots to
    /// get a tick delta, then pass to `recordCallback(machTicks:)`.
    static func now() -> UInt64 { mach_absolute_time() }

    private static func ticksToNs(_ ticks: UInt64) -> UInt64 {
        let tb = machTimebase
        return ticks &* UInt64(tb.numer) / UInt64(tb.denom)
    }

    // MARK: - 1 Hz tick: snapshot rates + memory + p99

    private func startRateTimer() {
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task { @MainActor in PerfMetrics.shared.tickRates() }
        }
        RunLoop.main.add(timer, forMode: .common)
        rateTimer = timer
    }

    private func stopRateTimer() {
        rateTimer?.invalidate()
        rateTimer = nil
    }

    private func tickRates() {
        eventTapEventsPerSec = eventBucket
        wipeCallsPerSec = wipeBucket
        mainHopsPerSec = mainHopBucket
        eventBucket = 0
        wipeBucket = 0
        mainHopBucket = 0
        memoryNowMB = Self.currentResidentMB()
        if !latencyRing.isEmpty {
            // 99th percentile from the rolling window. Sorting 1024 UInt64s is
            // ~10 µs — fine at 1 Hz.
            let sorted = latencyRing.sorted()
            let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count) * 0.99)))
            eventCallbackP99Ns = sorted[idx]
        }
        // Single publish per second — drives all view refreshes that observe
        // PerfMetrics. recordCallback / recordEvent / recordWipe never
        // publish from the hot path themselves.
        tickSeq &+= 1
    }

    // MARK: - Memory

    private static func currentResidentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1024 / 1024
    }

    // MARK: - Snapshot lines (consumed by DebugLog.snapshot)

    func snapshotLines() -> [String] {
        let avgUs = Double(eventCallbackAvgNs) / 1000
        let maxUs = Double(eventCallbackMaxNs) / 1000
        let p99Us = Double(eventCallbackP99Ns) / 1000
        return [
            "------ Performance ------",
            "callback latency:  avg=\(fmt(avgUs))µs  max=\(fmt(maxUs))µs  p99=\(fmt(p99Us))µs  · \(eventCallbackSamples) samples",
            "rates (last 1s):   events=\(eventTapEventsPerSec)/s  wipes=\(wipeCallsPerSec)/s  mainHops=\(mainHopsPerSec)/s",
            "allocations:       NSEvent=\(nsEventAllocations)  JSONenc=\(jsonEncodeCount)  JSONdec=\(jsonDecodeCount)  UDwrites=\(userDefaultsWrites)",
            "memory:            start=\(fmt(memoryStartMB))MB  now=\(fmt(memoryNowMB))MB  Δ=\(fmtSigned(memoryDeltaMB))MB",
        ]
    }

    private func fmt(_ d: Double) -> String { String(format: "%.1f", d) }
    private func fmtSigned(_ d: Double) -> String { String(format: "%+.1f", d) }

    // MARK: - Perf-test snapshot

    #if DEBUG
    /// Structured snapshot for the perf-test harness. Reads the rolling
    /// latency ring (fills only when verbosePerfEnabled is on, which the
    /// runner toggles for the test duration) and produces a JSON-ready
    /// payload with percentiles + a coarse histogram.
    struct PerfTestSnapshot: Encodable {
        let suite: String
        let mode: String
        let timestamp: String
        let durationMs: Int
        let config: Config
        let latencyUs: LatencyStats
        let counters: Counters
        let memory: Memory
        let histogramUs: [HistogramBin]
        let recentEvents: [String]

        struct Config: Encodable {
            let cellsPerAxis: Int
            let screenCount: Int
            let wipeMode: String
            let totalEventsRequested: Int
        }
        struct LatencyStats: Encodable {
            let avg: Int, p50: Int, p95: Int, p99: Int, p999: Int, max: Int, samples: Int
        }
        struct Counters: Encodable {
            let eventsTotal: Int
            let wipesTotal: Int
            let tapTimeouts: Int
            let nsEventAllocs: Int
            let userDefaultsWrites: Int
            let jsonEncodes: Int
            let jsonDecodes: Int
        }
        struct Memory: Encodable {
            let startMB: Double
            let endMB: Double
            let deltaMB: Double
        }
        struct HistogramBin: Encodable {
            let upperBoundUs: Int  // -1 = "no upper bound" for the last bin
            let count: Int
        }
    }

    func perfTestSnapshot(suite: String,
                          mode: String,
                          durationMs: Int,
                          totalEventsRequested: Int,
                          cellsPerAxis: Int,
                          screenCount: Int,
                          wipeMode: String) -> PerfTestSnapshot {
        let sorted = latencyRing.sorted()
        let percentileUs = { (frac: Double) -> Int in
            guard !sorted.isEmpty else { return 0 }
            let idx = Swift.max(0, Swift.min(sorted.count - 1, Int(Double(sorted.count) * frac)))
            return Int(sorted[idx] / 1000)
        }
        let avgUs = Int(eventCallbackAvgNs / 1000)
        let maxUs = Int(eventCallbackMaxNs / 1000)
        // Bin edges in µs — chosen to expose the regime transitions:
        // sub-100µs = healthy, 100-500µs = busy, 500-1000µs = strained,
        // 1-5ms = budget risk, 5-50ms = the tap WILL get disabled.
        let bins: [Int] = [100, 500, 1_000, 5_000, 50_000]
        var hist: [PerfTestSnapshot.HistogramBin] = []
        var idx = 0
        for upper in bins {
            var count = 0
            while idx < sorted.count && Int(sorted[idx] / 1000) < upper {
                count += 1
                idx += 1
            }
            hist.append(.init(upperBoundUs: upper, count: count))
        }
        hist.append(.init(upperBoundUs: -1, count: sorted.count - idx))

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]

        return PerfTestSnapshot(
            suite: suite,
            mode: mode,
            timestamp: iso.string(from: Date()),
            durationMs: durationMs,
            config: .init(
                cellsPerAxis: cellsPerAxis,
                screenCount: screenCount,
                wipeMode: wipeMode,
                totalEventsRequested: totalEventsRequested
            ),
            latencyUs: .init(
                avg: avgUs,
                p50: percentileUs(0.50),
                p95: percentileUs(0.95),
                p99: percentileUs(0.99),
                p999: percentileUs(0.999),
                max: maxUs,
                samples: eventCallbackSamples
            ),
            counters: .init(
                eventsTotal: eventCallbackSamples,
                wipesTotal: wipesTotal,
                tapTimeouts: tapTimeoutCount,
                nsEventAllocs: nsEventAllocations,
                userDefaultsWrites: userDefaultsWrites,
                jsonEncodes: jsonEncodeCount,
                jsonDecodes: jsonDecodeCount
            ),
            memory: .init(
                startMB: memoryStartMB,
                endMB: memoryNowMB,
                deltaMB: memoryDeltaMB
            ),
            histogramUs: hist,
            recentEvents: eventLines()
        )
    }
    #endif
}
