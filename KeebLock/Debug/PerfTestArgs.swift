#if DEBUG
import Foundation

/// CLI flags accepted by the perf-test harness. Parsed at app launch
/// from `CommandLine.arguments`; presence of `--perf-test=<suite>`
/// short-circuits the normal app UI and runs the harness instead.
///
/// Example: `KeebLock --perf-test=burst --mode=A --output=/tmp/keeblock-perf.json`
struct PerfTestArgs {
    enum Suite: String {
        case burst
        case saveStorm = "savestorm"
        /// Interleaves synthetic mouseMoved at 60 Hz with keyDown at 100 Hz.
        /// Targets the cursor-flicker symptom that only reproduces when the
        /// mouse has moved before/during a typing burst — pure key bursts
        /// (`burst`/`saveStorm`) never reach that pre-condition.
        case mouseKeyMix = "mousekeymix"
    }
    enum Mode: String {
        /// Direct call into LockController._testInjectEvent. No real CGEvent.post.
        /// Cannot lock the user out under any circumstance. Default.
        case directInject = "A"
        /// Real CGEvent.post into the OS tap stream. Reproduces the cursor-
        /// flicker symptom but requires safety pre-flight checks before
        /// every post.
        case realOSPost = "B"
    }

    let suite: Suite
    let mode: Mode
    let outputPath: String

    static func fromCommandLine() -> PerfTestArgs? {
        let argv = CommandLine.arguments
        guard let suiteRaw = value(for: "--perf-test", in: argv),
              let suite = Suite(rawValue: suiteRaw.lowercased())
        else { return nil }

        let modeRaw = value(for: "--mode", in: argv) ?? "A"
        let mode = Mode(rawValue: modeRaw.uppercased()) ?? .directInject

        let defaultOutput = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("keeblock-perf.json")
        let outputPath = value(for: "--output", in: argv) ?? defaultOutput

        return PerfTestArgs(suite: suite, mode: mode, outputPath: outputPath)
    }

    /// Parses `--key=value` and `--key value` styles from argv.
    private static func value(for key: String, in argv: [String]) -> String? {
        let prefix = key + "="
        for (i, arg) in argv.enumerated() {
            if arg.hasPrefix(prefix) {
                return String(arg.dropFirst(prefix.count))
            }
            if arg == key, i + 1 < argv.count {
                let next = argv[i + 1]
                // A following token that looks like a flag means the value was
                // forgotten; treat it as missing so the omission surfaces
                // instead of silently swallowing the next flag.
                return next.hasPrefix("--") ? nil : next
            }
        }
        return nil
    }
}
#endif
