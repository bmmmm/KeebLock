import AVFoundation
import AppKit

// Plays a click on each keystroke. Two modes:
// 1. Synthesized burst (default) — 18 ms exponentially-decaying white-noise click,
//    generated at init, played via AVAudioEngine + AVAudioPlayerNode.
// 2. User-supplied audio file — resolved via security-scoped bookmark, played via
//    AVAudioPlayer (simpler API, file-based).
//
// IMPORTANT: play() must return in < 1 ms because it is called from the CGEventTap
// callback (MainActor). All audio I/O is dispatched async to avoid blocking the
// event tap and causing perceived input lag.
final class SoundPlayer {

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat?
    private var clickBuffer: AVAudioPCMBuffer?

    private var customPlayer: AVAudioPlayer?
    /// Security-scoped URL for the currently-loaded custom file. Held for
    /// the lifetime of `customPlayer` — released on swap, stop, or deinit.
    /// Releasing earlier (via `defer` inside `setCustomFile`) leaves
    /// `AVAudioPlayer` accessing a path whose scope is closed; the file
    /// descriptor is cached on the player but the scope contract is broken
    /// and TCC re-evaluations can silence playback intermittently.
    private var customScopedURL: URL?

    private var lastPlayTime: TimeInterval = -.infinity
    // 80 ms throttle. macOS 26+ tightened CoreAudio's HALC scheduler
    // tolerance, so the original 50 ms cap was producing "skipping
    // cycle due to overload" warnings under sustained typing + active
    // gesture streams (pinch/swipe each fire at ~60 Hz before our
    // debounce). 80 ms = 12 plays/s is still plenty dense for tactile
    // click feedback and lets HAL stay in its budget.
    private let throttleInterval: TimeInterval = 0.08

    // High-priority serial queue for AVAudioEngine/PlayerNode scheduling.
    // AVAudioPlayerNode.scheduleBuffer is thread-safe and can be called from here.
    private let audioQueue = DispatchQueue(label: "keeblock.audio", qos: .userInteractive)

    init() {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)
        self.format = fmt
        guard let format = fmt else { return }

        let frameCount = AVAudioFrameCount(Int(44100 * 0.018))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let t = Float(i) / 44100.0
            // Amplitude 1.0: full PCM headroom. Earlier 0.25 capped peak loudness
            // at -12 dB regardless of slider position, so users on quiet outputs
            // (laptop speakers in a noisy room) couldn't get audible feedback.
            // The slider's `playerNode.volume` (0…1) still attenuates from here.
            samples[i] = Float.random(in: -1.0...1.0) * expf(-t * 300.0)
        }
        clickBuffer = buffer

        // Connect and start eagerly so the first keystroke doesn't pay engine-init latency.
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            DebugLog.log("SoundPlayer: AVAudioEngine start failed at init: \(error.localizedDescription)")
        }
    }

    // MARK: - Public

    /// Volume mapping:
    ///   0…1.0 — normal range, set on playerNode (and customPlayer where present).
    ///   1.0…2.0 — overdrive: playerNode stays at 1.0 (its hard cap), the
    ///   extra gain rides on the engine's main mixer (outputVolume), which
    ///   accepts >1.0 and pushes the synth-click into hard-clip territory.
    ///   Audible as harsher attack — intentional, that's what the red zone
    ///   in the slider signals.
    ///
    ///   AVAudioPlayer (custom file mode) clamps .volume at 1.0 internally,
    ///   so the boost only affects the synth-click path. Documented here
    ///   so future work doesn't rely on file-mode going louder.
    func setVolume(_ volume: Double) {
        let v = max(0, min(2.0, volume))
        let nodeVol = Float(min(1.0, v))
        let mixerVol = Float(max(1.0, v))
        playerNode.volume = nodeVol
        engine.mainMixerNode.outputVolume = mixerVol
        customPlayer?.volume = nodeVol
    }

    func setCustomFile(bookmark: Data?) {
        // Release scope from a previous custom file before swapping.
        customScopedURL?.stopAccessingSecurityScopedResource()
        customScopedURL = nil
        customPlayer = nil

        guard let bookmark else { return }

        var stale = false
        let url: URL
        do {
            url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            DebugLog.log("SoundPlayer: bookmark resolution failed: \(error.localizedDescription)")
            return
        }

        // A stale bookmark may resolve to a moved or replaced file. Bail —
        // re-picking the file in Settings forces a fresh bookmark and is
        // safer than silently playing whatever happens to live at the path
        // the OS guessed.
        if stale {
            DebugLog.log("SoundPlayer: bookmark stale for \(url.lastPathComponent) — discarding; user must re-pick the file")
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            DebugLog.log("SoundPlayer: could not access security-scoped resource")
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.volume = playerNode.volume
            customPlayer = p
            // Scope held until next setCustomFile() / stop() / deinit —
            // matches the lifetime of the AVAudioPlayer's open file.
            customScopedURL = url
            DebugLog.log("SoundPlayer: loaded custom file \(url.lastPathComponent) duration=\(p.duration)s")
        } catch {
            url.stopAccessingSecurityScopedResource()
            DebugLog.log("SoundPlayer: failed to load custom file: \(error.localizedDescription)")
        }
    }

    // Called from the CGEventTap callback on the Main thread.
    // Does only a fast throttle check on the calling thread and immediately
    // dispatches all audio I/O async — never blocks the event tap.
    func play() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastPlayTime >= throttleInterval else { return }
        lastPlayTime = now

        if customPlayer != nil {
            // AVAudioPlayer is not thread-safe; dispatch async to main (non-blocking —
            // returns before executing, so the event tap is free immediately).
            DispatchQueue.main.async { [weak self] in
                guard let p = self?.customPlayer else { return }
                p.currentTime = 0
                p.play()
            }
        } else {
            // AVAudioPlayerNode.scheduleBuffer is thread-safe.
            audioQueue.async { [weak self] in
                self?.playSynthClick()
            }
        }
    }

    func stop() {
        playerNode.stop()
        engine.stop()
        customPlayer?.stop()
        customScopedURL?.stopAccessingSecurityScopedResource()
        customScopedURL = nil
    }

    deinit {
        customScopedURL?.stopAccessingSecurityScopedResource()
    }

    /// Brief celebratory chime, played when the lock unlocks. Bypasses the
    /// per-keystroke throttle so a single trigger always sounds.
    func playUnlockChime() {
        DispatchQueue.global(qos: .userInitiated).async {
            // Use a system sound so we don't have to bundle a separate WAV.
            // "Glass" is short, melodic, and ships on every Mac.
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
    }

    // MARK: - Diagnostics

    var engineLatencyMs: Double {
        engine.outputNode.presentationLatency * 1000
    }

    var engineSampleRate: Int {
        Int(engine.outputNode.outputFormat(forBus: 0).sampleRate)
    }

    var engineStatus: String {
        engine.isRunning ? "running" : "stopped"
    }

    // MARK: - Private

    private func playSynthClick() {
        guard let buffer = clickBuffer else { return }
        if !engine.isRunning {
            try? engine.start()
        }
        playerNode.scheduleBuffer(buffer, at: nil, options: [])
        if !playerNode.isPlaying { playerNode.play() }
    }
}
