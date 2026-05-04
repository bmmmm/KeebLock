import AVFoundation

// Synthesized noise-burst click: no binary asset required.
// Generates an 18ms exponentially-decaying white-noise burst at init and stores it
// in a pre-allocated PCMBuffer.
//
// AVAudioEngine.start() is deferred until the first play() to avoid pinning the
// audio I/O hardware during app launch. Stopping the engine in stop() releases the
// audio I/O context — keeps HALC quiet when the app is idle.
final class SoundPlayer {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat?
    private var clickBuffer: AVAudioPCMBuffer?
    private var lastPlayTime: TimeInterval = -.infinity
    private let throttleInterval: TimeInterval = 0.03
    private var graphConnected = false

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
        // Connect happens lazily in play(), to keep the audio graph idle until needed.
    }

    func play() {
        guard let buffer = clickBuffer, let format else { return }
        let now = Date().timeIntervalSinceReferenceDate
        guard now - lastPlayTime >= throttleInterval else { return }
        lastPlayTime = now

        if !graphConnected {
            engine.connect(playerNode, to: engine.mainMixerNode, format: format)
            graphConnected = true
        }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                NSLog("[KeebLock] AVAudioEngine start failed: %@", error.localizedDescription)
                return
            }
        }
        playerNode.scheduleBuffer(buffer, at: nil, options: [])
        if !playerNode.isPlaying { playerNode.play() }
    }

    func stop() {
        playerNode.stop()
        engine.stop()
    }
}
