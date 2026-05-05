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
            samples[i] = Float.random(in: -1.0...1.0) * expf(-t * 300.0) * 0.25
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

    func setVolume(_ volume: Double) {
        let v = Float(max(0, min(1, volume)))
        playerNode.volume = v
        customPlayer?.volume = v
    }

    func setCustomFile(bookmark: Data?) {
        customPlayer = nil
        guard let bookmark else { return }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            // A stale bookmark may resolve to a moved or replaced file. Bail
            // out — re-picking the file in Settings forces a fresh bookmark
            // and is safer than silently playing whatever happens to live at
            // the path the OS guessed.
            if stale {
                DebugLog.log("SoundPlayer: bookmark stale for \(url.lastPathComponent) — discarding; user must re-pick the file")
                return
            }
            guard url.startAccessingSecurityScopedResource() else {
                DebugLog.log("SoundPlayer: could not access security-scoped resource")
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.volume = playerNode.volume
            customPlayer = p
            DebugLog.log("SoundPlayer: loaded custom file \(url.lastPathComponent) duration=\(p.duration)s")
        } catch {
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
