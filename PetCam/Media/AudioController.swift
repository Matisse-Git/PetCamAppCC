import AVFoundation

/// Plays the camera's microphone audio and, while talking, captures the phone's microphone
/// with Apple's voice processing (echo cancellation) and encodes it to G.711 A-law.
///
/// The engine is rebuilt whenever we switch between listen-only and talk mode, because
/// voice processing and the audio session category can only change while the engine is stopped.
final class AudioController: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var queuedFrames = 0
    private var muted = false
    private var talking = false
    private var talkSink: (([UInt8]) -> Void)?
    private var talkBuffer: [UInt8] = []

    private let playbackFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 8000, channels: 1, interleaved: false)!
    private let talkFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!

    /// Keep at most ~0.4 s of camera audio queued so latency can't build up.
    private let maxQueuedFrames = 3200

    init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            let isTalking = self.lock.withLock { self.talking }
            try? self.rebuild(talk: isTalking)
        }
    }

    // MARK: Lifecycle

    func startListening() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
            try rebuild(talk: false)
        } catch {
            print("PetCam audio: could not start playback: \(error)")
        }
    }

    func stop() {
        lock.withLock {
            engine?.stop()
            engine = nil
            player = nil
            talking = false
            talkSink = nil
        }
    }

    func setMuted(_ value: Bool) {
        let node: AVAudioPlayerNode? = lock.withLock {
            muted = value
            return value ? player : nil
        }
        // Drop whatever is still queued so muting is instant.
        if let node {
            node.stop()
            lock.withLock { queuedFrames = 0 }
            node.play()
        }
    }

    // MARK: Camera → phone

    func play(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let target: (AVAudioPlayerNode, Float)? = lock.withLock {
            guard !muted, let player, queuedFrames < maxQueuedFrames else { return nil }
            queuedFrames += samples.count
            return (player, talking ? 0.35 : 1.0)
        }
        guard case let (node, gain)? = target,
              let buffer = AVAudioPCMBuffer(pcmFormat: playbackFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for i in 0..<samples.count {
            channel[i] = Float(samples[i]) / 32768 * gain
        }
        let count = samples.count
        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.queuedFrames = max(0, self.queuedFrames - count) }
        }
    }

    // MARK: Phone → camera

    /// Switches to talk mode. `sink` receives 320-byte A-law chunks on an audio thread.
    func startTalking(sink: @escaping ([UInt8]) -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker])
        try session.setActive(true)
        lock.withLock {
            talkSink = sink
            talkBuffer.removeAll()
            talking = true
        }
        do {
            try rebuild(talk: true)
        } catch {
            lock.withLock {
                talking = false
                talkSink = nil
            }
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            try? rebuild(talk: false)
            throw error
        }
    }

    func stopTalking() {
        let wasTalking: Bool = lock.withLock {
            let was = talking
            talking = false
            talkSink = nil
            return was
        }
        guard wasTalking else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
            try rebuild(talk: false)
        } catch {
            print("PetCam audio: could not leave talk mode: \(error)")
        }
    }

    // MARK: Engine

    private func rebuild(talk: Bool) throws {
        lock.withLock {
            engine?.stop()
            engine = nil
            player = nil
            queuedFrames = 0
        }

        let newEngine = AVAudioEngine()
        let newPlayer = AVAudioPlayerNode()

        if talk {
            try newEngine.inputNode.setVoiceProcessingEnabled(true)
        }
        newEngine.attach(newPlayer)
        newEngine.connect(newPlayer, to: newEngine.mainMixerNode, format: playbackFormat)

        if talk {
            let input = newEngine.inputNode
            let inputFormat = input.outputFormat(forBus: 0)
            guard inputFormat.sampleRate > 0, let converter = AVAudioConverter(from: inputFormat, to: talkFormat) else {
                throw NSError(domain: "PetCam.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone unavailable"])
            }
            converter.downmix = true
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
                self?.encodeMicrophone(buffer, converter: converter)
            }
        }

        newEngine.prepare()
        try newEngine.start()
        newPlayer.play()

        lock.withLock {
            engine = newEngine
            player = newPlayer
        }
    }

    private func encodeMicrophone(_ buffer: AVAudioPCMBuffer, converter: AVAudioConverter) {
        let ratio = talkFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: talkFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = output.int16ChannelData?[0] else { return }

        let count = Int(output.frameLength)
        var encoded = [UInt8](repeating: 0, count: count)
        for i in 0..<count {
            encoded[i] = G711.alawEncode(samples[i])
        }

        let chunks: ([[UInt8]], (([UInt8]) -> Void)?) = lock.withLock {
            talkBuffer.append(contentsOf: encoded)
            var ready: [[UInt8]] = []
            while talkBuffer.count >= 320 {
                ready.append(Array(talkBuffer.prefix(320)))
                talkBuffer.removeFirst(320)
            }
            return (ready, talkSink)
        }
        guard let sink = chunks.1 else { return }
        chunks.0.forEach(sink)
    }
}
