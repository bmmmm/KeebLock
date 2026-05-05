import AVFoundation
import AppKit

// Plays a click on each keystroke. Two modes:
// 1. Synthesized burst (default) — 18 ms exponentially-decaying white-noise click,
//    generated at init, played via AVAudioEngine + AVAudioPlayerNode.
// 2. User-supplied audio file — resolved via security-scoped bookmark, played via
//    AVAudioPlayer (simpler API, file-based, decoupled from the click engine).
//
// AVAudioEngine.start() is deferred to first play() to keep the audio HAL idle at
// launch. Throttled to 30 ms so a held key doesn't crackle.
final class SoundPlayer {

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat?
    private var clickBuffer: AVAudioPCMBuffer?
    private var graphConnected = false

    private var customPlayer: AVAudioPlayer?
    private var customBookmarkData: Data?

    private var lastPlayTime: TimeInterval = -.infinity
    private let throttleInterval: TimeInterval = 0.03

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

        engine.attach(playerNode)
    }

    // MARK: - Public

    /// Volume 0.0 ... 1.0. Applies to both synth and custom-file modes.
    func setVolume(_ volume: Double) {
        let v = Float(max(0, min(1, volume)))
        playerNode.volume = v
        customPlayer?.volume = v
    }

    /// Load an audio file by security-scoped bookmark. Pass nil to revert to synth click.
    func setCustomFile(bookmark: Data?) {
        customBookmarkData = bookmark
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

    func play() {
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastPlayTime >= throttleInterval else { return }
        lastPlayTime = now

        if let p = customPlayer {
            p.currentTime = 0
            p.play()
            return
        }
        playSynthClick()
    }

    func stop() {
        playerNode.stop()
        engine.stop()
        customPlayer?.stop()
    }

    // MARK: - Private

    private func playSynthClick() {
        guard let buffer = clickBuffer, let format else { return }
        if !graphConnected {
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            graphConnected = true
        }
        if !engine.isRunning {
            do { try engine.start() }
            catch {
                DebugLog.log("SoundPlayer: AVAudioEngine start failed: \(error.localizedDescription)")
                return
            }
        }
        playerNode.scheduleBuffer(buffer, at: nil, options: [])
        if !playerNode.isPlaying { playerNode.play() }
    }
}
