import AVFoundation

// Synthesized noise-burst click: no binary asset required.
// Generates an 18ms exponentially-decaying white-noise burst at init, stores it
// in a pre-allocated PCMBuffer, and replays it via AVAudioPlayerNode.
// Throttled to 30 ms so held keys don't produce crackling.
final class SoundPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var clickBuffer: AVAudioPCMBuffer?
    private var lastPlayTime: TimeInterval = -.infinity
    private let throttleInterval: TimeInterval = 0.03

    init() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1) else { return }
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
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            NSLog("[KeebLock] AVAudioEngine start failed: %@", error.localizedDescription)
        }
    }

    func play() {
        guard let buffer = clickBuffer else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastPlayTime >= throttleInterval else { return }
        lastPlayTime = now
        if !engine.isRunning { try? engine.start() }
        playerNode.scheduleBuffer(buffer, at: nil, options: [])
        if !playerNode.isPlaying { playerNode.play() }
    }

    func stop() {
        playerNode.stop()
        engine.stop()  // release audio I/O — prevents HALC_ProxyIOContext overload
    }
}
