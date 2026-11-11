import AVFoundation

/// Records the live stream to a .mov without re-encoding: video is passed through as
/// H.264/H.265 and the camera audio is stored as 8 kHz 16-bit PCM.
final class ClipRecorder: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "petcam.recorder")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var started = false
    private var finished = false
    private let audioFormat: CMAudioFormatDescription?

    init() {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("PetCam-\(UUID().uuidString).mov")
        audioFormat = Self.makeAudioFormat()
    }

    func appendVideo(_ sample: CMSampleBuffer, keyframe: Bool) {
        queue.async { [self] in
            guard !finished else { return }
            if !started {
                // A clip has to begin on a keyframe.
                guard keyframe, let format = CMSampleBufferGetFormatDescription(sample) else { return }
                guard startWriter(videoFormat: format, at: CMSampleBufferGetPresentationTimeStamp(sample)) else {
                    finished = true
                    return
                }
            }
            if let videoInput, videoInput.isReadyForMoreMediaData {
                videoInput.append(sample)
            }
        }
    }

    func appendAudio(_ samples: [Int16], pts: CMTime) {
        queue.async { [self] in
            guard started, !finished, let audioInput, audioInput.isReadyForMoreMediaData,
                  let sample = makeAudioSample(samples, pts: pts) else { return }
            audioInput.append(sample)
        }
    }

    /// Finishes the file. Returns its URL, or nil if nothing usable was recorded.
    func finish() async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            queue.async { [self] in
                finished = true
                guard started, let writer else {
                    continuation.resume(returning: nil)
                    return
                }
                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                writer.finishWriting { [url] in
                    continuation.resume(returning: writer.status == .completed ? url : nil)
                }
            }
        }
    }

    private func startWriter(videoFormat: CMFormatDescription, at time: CMTime) -> Bool {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return false }
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { return false }
        writer.add(video)

        if let audioFormat {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            }
        }

        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: time)
        self.writer = writer
        videoInput = video
        started = true
        return true
    }

    private static func makeAudioFormat() -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 8000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    private func makeAudioSample(_ samples: [Int16], pts: CMTime) -> CMSampleBuffer? {
        guard let audioFormat, !samples.isEmpty else { return nil }
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }

        let copied = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: audioFormat,
            sampleCount: samples.count,
            presentationTimeStamp: pts,
            packetDescriptions: nil,
            sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}
