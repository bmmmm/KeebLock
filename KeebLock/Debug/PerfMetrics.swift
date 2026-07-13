import Combine
import CoreGraphics
import Darwin
import Foundation

// Lightweight in-process telemetry for the lock loop. Counters are bumped from
// hot paths (event-tap callback, wipe scheduler, JSON I/O) and surfaced via
// the Settings → Debug panel and DebugLog snapshots. All public state is
// MainActor-isolated to match the project default; hot-path bumps are cheap
// integer mutations on the same actor that drives the event tap callback.
//
// Toggle: AppSettings.shared.verbosePerfEnabled now gates only the
// per-event STRING work (recordEvent / event ring). Callback-latency
// sampling + percentile rings run unconditionally — they cost ~10 ns
// each and we want production-truth percentiles without flipping a
// debug toggle that itself inflates the numbers.
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
    /// Derived lazily from `eventCallbackTotalNs` / `eventCallbackSamples` at
    /// read time — no per-event division on the tap-callback hot path.
    var eventCallbackAvgNs: UInt64 {
        eventCallbackSamples > 0 ? eventCallbackTotalNs / UInt64(eventCallbackSamples) : 0
    }
    private(set) var eventCallbackP99Ns: UInt64 = 0
    private(set) var eventCallbackSamples: Int = 0

    // MARK: - Per-type latency split (key vs mouse)
    // Filled in lockstep with the combined stats above on every callback
    // (always-on since Training 3, 2026-05-20). Lets us see whether mouse
    // callback latency degrades during keyDown bursts — the proxy metric
    // for "MainActor saturation under mixed load" (hypothesis A for the
    // cursor-flicker symptom).
    private(set) var keyCallbackMaxNs: UInt64 = 0
    /// Same lazy-derivation as `eventCallbackAvgNs`.
    var keyCallbackAvgNs: UInt64 {
        keyCallbackSamples > 0 ? keyCallbackTotalNs / UInt64(keyCallbackSamples) : 0
    }
    private(set) var keyCallbackP99Ns: UInt64 = 0
    private(set) var keyCallbackSamples: Int = 0
    private(set) var mouseCallbackMaxNs: UInt64 = 0
    /// Same lazy-derivation as `eventCallbackAvgNs`.
    var mouseCallbackAvgNs: UInt64 {
        mouseCallbackSamples > 0 ? mouseCallbackTotalNs / UInt64(mouseCallbackSamples) : 0
    }
    private(set) var mouseCallbackP99Ns: UInt64 = 0
    private(set) var mouseCallbackSamples: Int = 0

    // MARK: - Per-second rates (sliding 1 s bucket)
    private(set) var eventTapEventsPerSec: Int = 0
    private(set) var mouseEventsPerSec: Int = 0
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

    // Per-type ring buffers — same capacity as the combined ring so each
    // can independently produce a p99. Keeping them separate also means
    // mouseMoved at 60 Hz can't push keyDown samples out of the combined
    // window during a mousekeymix run.
    private var keyLatencyRing: [UInt64] = []
    private var keyLatencyRingHead = 0
    private var keyCallbackTotalNs: UInt64 = 0
    private var mouseLatencyRing: [UInt64] = []
    private var mouseLatencyRingHead = 0
    private var mouseCallbackTotalNs: UInt64 = 0

    private var eventBucket = 0
    private var mouseEventBucket = 0
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
        eventCallbackP99Ns = 0
        eventCallbackSamples = 0
        eventCallbackTotalNs = 0
        latencyRing.removeAll(keepingCapacity: true)
        latencyRingHead = 0

        keyCallbackMaxNs = 0
        keyCallbackP99Ns = 0
        keyCallbackSamples = 0
        keyCallbackTotalNs = 0
        keyLatencyRing.removeAll(keepingCapacity: true)
        keyLatencyRingHead = 0
        mouseCallbackMaxNs = 0
        mouseCallbackP99Ns = 0
        mouseCallbackSamples = 0
        mouseCallbackTotalNs = 0
        mouseLatencyRing.removeAll(keepingCapacity: true)
        mouseLatencyRingHead = 0

        eventTapEventsPerSec = 0
        mouseEventsPerSec = 0
        wipeCallsPerSec = 0
        mainHopsPerSec = 0
        eventBucket = 0
        mouseEventBucket = 0
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
    /// is off (single bool check + return). `tag` is autoclosured so
    /// interpolated call-sites (`"mouseAux btn=\(button)"` etc.) don't
    /// build the string at all on the hot path when verbose is off.
    func recordEvent(_ tag: @autoclosure () -> String) {
        guard AppSettings.shared.verbosePerfEnabled else { return }
        let elapsedMs = Self.ticksToNs(mach_absolute_time() &- sessionStartTicks) / 1_000_000
        let line = "+\(elapsedMs)ms \(tag())"
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

    func recordCallback(machTicks: UInt64, type: CGEventType) {
        eventBucket &+= 1
        if Self.isMouseType(type) { mouseEventBucket &+= 1 }
        let ns = Self.ticksToNs(machTicks)

        // Latency sampling runs UNCONDITIONALLY — the ring updates are
        // ~10 ns each (single Int compare + array slot write), small
        // enough that they don't bias the measurement they record. The
        // verbose-perf gate sits lower, around the string-allocating
        // `recordEvent` path; that's where the real overhead lives.
        // Always-on percentiles let us audit Release-mode latency
        // without flipping a debug toggle that itself inflates the
        // numbers (the original chicken-and-egg of Training 3).

        // Combined stats — unchanged for downstream consumers that still
        // read the aggregated avg/max/p99.
        eventCallbackSamples &+= 1
        if ns > eventCallbackMaxNs { eventCallbackMaxNs = ns }
        eventCallbackTotalNs &+= ns
        if latencyRing.count < latencyRingCapacity {
            latencyRing.append(ns)
        } else {
            latencyRing[latencyRingHead] = ns
            latencyRingHead = (latencyRingHead &+ 1) % latencyRingCapacity
        }

        // Per-type split. Gestures, NX_SYSDEFINED, and tap-disabled events
        // intentionally feed only the combined ring — their latency
        // characteristics differ enough that mixing them into the
        // mouse/key buckets would muddy the proxy metric.
        if Self.isKeyType(type) {
            recordKeyLatency(ns: ns)
        } else if Self.isMouseType(type) {
            recordMouseLatency(ns: ns)
        }
    }

    private func recordKeyLatency(ns: UInt64) {
        keyCallbackSamples &+= 1
        if ns > keyCallbackMaxNs { keyCallbackMaxNs = ns }
        keyCallbackTotalNs &+= ns
        if keyLatencyRing.count < latencyRingCapacity {
            keyLatencyRing.append(ns)
        } else {
            keyLatencyRing[keyLatencyRingHead] = ns
            keyLatencyRingHead = (keyLatencyRingHead &+ 1) % latencyRingCapacity
        }
    }

    private func recordMouseLatency(ns: UInt64) {
        mouseCallbackSamples &+= 1
        if ns > mouseCallbackMaxNs { mouseCallbackMaxNs = ns }
        mouseCallbackTotalNs &+= ns
        if mouseLatencyRing.count < latencyRingCapacity {
            mouseLatencyRing.append(ns)
        } else {
            mouseLatencyRing[mouseLatencyRingHead] = ns
            mouseLatencyRingHead = (mouseLatencyRingHead &+ 1) % latencyRingCapacity
        }
    }

    private static func isKeyType(_ type: CGEventType) -> Bool {
        type == .keyDown || type == .keyUp || type == .flagsChanged
    }

    private static func isMouseType(_ type: CGEventType) -> Bool {
        switch type {
        case .mouseMoved, .leftMouseDown, .leftMouseDragged,
             .rightMouseDown, .rightMouseDragged,
             .otherMouseDown, .otherMouseDragged, .scrollWheel:
            return true
        default:
            return false
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
        // Never leak a previously-scheduled timer: a second sessionStart()
        // without an intervening sessionStop() (e.g. the perf-test restart)
        // would otherwise orphan the old timer on the main runloop, where it
        // keeps firing and double-resets the rate buckets.
        rateTimer?.invalidate()
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
        mouseEventsPerSec = mouseEventBucket
        wipeCallsPerSec = wipeBucket
        mainHopsPerSec = mainHopBucket
        eventBucket = 0
        mouseEventBucket = 0
        wipeBucket = 0
        mainHopBucket = 0
        memoryNowMB = Self.currentResidentMB()
        // 99th percentile from each rolling window. Sorting 1024 UInt64s is
        // ~10 µs — fine at 1 Hz, even when we now do it three times.
        eventCallbackP99Ns = Self.p99(of: latencyRing)
        keyCallbackP99Ns = Self.p99(of: keyLatencyRing)
        mouseCallbackP99Ns = Self.p99(of: mouseLatencyRing)
        // Single publish per second — drives all view refreshes that observe
        // PerfMetrics. recordCallback / recordEvent / recordWipe never
        // publish from the hot path themselves.
        tickSeq &+= 1
    }

    private static func p99(of ring: [UInt64]) -> UInt64 {
        Self.percentile(of: ring.sorted(), frac: 0.99)
    }

    /// Nearest-rank percentile over an already-sorted ascending array.
    /// Undersample guard: a fraction `frac` needs at least `1/(1-frac)`
    /// samples before the nearest-rank index can land below the maximum
    /// (n=2 → p99 index 1 == max; n=50 → p999 index 49 == max). Below that
    /// threshold the percentile is indistinguishable from `max`, so we
    /// return `max` deliberately rather than passing it off as a meaningful
    /// p99/p999. The large-n path (count ≥ threshold) is the plain
    /// nearest-rank index, unchanged.
    private static func percentile(of sorted: [UInt64], frac: Double) -> UInt64 {
        guard let last = sorted.last else { return 0 }
        let threshold = Int((1.0 / (1.0 - frac)).rounded(.up))
        guard sorted.count >= threshold else { return last }
        let idx = Swift.max(0, Swift.min(sorted.count - 1, Int(Double(sorted.count) * frac)))
        return sorted[idx]
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
        let keyAvgUs = Double(keyCallbackAvgNs) / 1000
        let keyMaxUs = Double(keyCallbackMaxNs) / 1000
        let keyP99Us = Double(keyCallbackP99Ns) / 1000
        let mouseAvgUs = Double(mouseCallbackAvgNs) / 1000
        let mouseMaxUs = Double(mouseCallbackMaxNs) / 1000
        let mouseP99Us = Double(mouseCallbackP99Ns) / 1000
        return [
            "------ Performance ------",
            "callback latency:  avg=\(fmt(avgUs))µs  max=\(fmt(maxUs))µs  p99=\(fmt(p99Us))µs  · \(eventCallbackSamples) samples",
            // Per-type split — useful when the combined number looks healthy
            // but one event class is bottlenecking. Mouse spike during a
            // keyDown burst is the proxy metric for MainActor saturation.
            "  key latency:     avg=\(fmt(keyAvgUs))µs  max=\(fmt(keyMaxUs))µs  p99=\(fmt(keyP99Us))µs  · \(keyCallbackSamples) samples",
            "  mouse latency:   avg=\(fmt(mouseAvgUs))µs  max=\(fmt(mouseMaxUs))µs  p99=\(fmt(mouseP99Us))µs  · \(mouseCallbackSamples) samples",
            "rates (last 1s):   events=\(eventTapEventsPerSec)/s  mouse=\(mouseEventsPerSec)/s  wipes=\(wipeCallsPerSec)/s  mainHops=\(mainHopsPerSec)/s",
            "allocations:       NSEvent=\(nsEventAllocations)  JSONenc=\(jsonEncodeCount)  JSONdec=\(jsonDecodeCount)  UDwrites=\(userDefaultsWrites)",
            // tapTimeouts is the smoking-gun for the cursor-flicker / typing-lag
            // symptom: every increment is one moment where macOS disabled our
            // event tap because the callback blew its time budget. Non-zero
            // here under typical use confirms the diagnosis.
            "tap-health:        tapTimeouts=\(tapTimeoutCount)  wipesTotal=\(wipesTotal)",
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
        let latencyUs: LatencyStats          // combined (all event types)
        let keyLatencyUs: LatencyStats       // keyDown/Up + flagsChanged
        let mouseLatencyUs: LatencyStats     // mouseMoved/dragged/down + scroll
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
            let mouseEventsTotal: Int
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
        // Sort the combined ring once and reuse it for both the histogram
        // and the combined latencyStats below — latencyStats now takes a
        // pre-sorted array, so the same sorted copy serves both consumers
        // instead of sorting the same data twice at snapshot time.
        let sortedCombined = latencyRing.sorted()
        let sorted = sortedCombined
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
            latencyUs: Self.latencyStats(
                sorted: sortedCombined,
                avgNs: eventCallbackAvgNs,
                maxNs: eventCallbackMaxNs,
                samples: eventCallbackSamples
            ),
            keyLatencyUs: Self.latencyStats(
                sorted: keyLatencyRing.sorted(),
                avgNs: keyCallbackAvgNs,
                maxNs: keyCallbackMaxNs,
                samples: keyCallbackSamples
            ),
            mouseLatencyUs: Self.latencyStats(
                sorted: mouseLatencyRing.sorted(),
                avgNs: mouseCallbackAvgNs,
                maxNs: mouseCallbackMaxNs,
                samples: mouseCallbackSamples
            ),
            counters: .init(
                eventsTotal: eventCallbackSamples,
                mouseEventsTotal: mouseCallbackSamples,
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

    /// `sorted` must be the latency ring already sorted ascending — the
    /// caller sorts once and reuses it (the combined ring also feeds the
    /// histogram). Percentiles go through `percentile(of:frac:)`, which
    /// carries the undersample guard: for small n a requested p99/p999
    /// returns `max` deliberately instead of masquerading as a percentile.
    private static func latencyStats(sorted: [UInt64],
                                     avgNs: UInt64,
                                     maxNs: UInt64,
                                     samples: Int) -> PerfTestSnapshot.LatencyStats {
        let percentileUs = { (frac: Double) -> Int in
            Int(Self.percentile(of: sorted, frac: frac) / 1000)
        }
        return .init(
            avg: Int(avgNs / 1000),
            p50: percentileUs(0.50),
            p95: percentileUs(0.95),
            p99: percentileUs(0.99),
            p999: percentileUs(0.999),
            max: Int(maxNs / 1000),
            samples: samples
        )
    }
    #endif
}
