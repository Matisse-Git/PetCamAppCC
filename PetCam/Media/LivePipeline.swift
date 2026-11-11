import AVFoundation
import CoreImage
import UIKit

/// Shows decoded frames. Owned by the session so Picture-in-Picture keeps the same layer.
final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect

        var timebase: CMTimebase?
        let clock = CMClockGetHostTimeClock()
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: clock, timebaseOut: &timebase) == noErr,
           let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(clock))
            CMTimebaseSetRate(timebase, rate: 1)
            displayLayer.controlTimebase = timebase
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func enqueue(_ sample: CMSampleBuffer) {
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    func clear() {
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}

/// Media path for one live stream: DVRIP chunks → frames → decoder/display, audio and recorder.
/// `handle` is called on the media connection's serial queue.
final class LivePipeline: @unchecked Sendable {
    private let parser = XMMediaParser()
    private let decoder = VideoDecoder()
    private let audio: AudioController
    private weak var videoView: VideoLayerView?

    private let lock = NSLock()
    private var recorder: ClipRecorder?
    private var latestFrame: CVPixelBuffer?
    private var lastSize: CGSize = .zero

    /// Main thread. Called for the first frame and whenever the picture size changes.
    var onVideoSize: ((CGSize) -> Void)?

    init(videoView: VideoLayerView, audio: AudioController) {
        self.videoView = videoView
        self.audio = audio
        decoder.onDecoded = { [weak self] pixelBuffer, pts in
            self?.show(pixelBuffer, pts: pts)
        }
        decoder.onCompressed = { [weak self] sample, keyframe in
            guard let self else { return }
            let recorder = self.lock.withLock { self.recorder }
            recorder?.appendVideo(sample, keyframe: keyframe)
        }
    }

    func handle(_ data: Data) {
        parser.push(data) { frame in
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            switch frame {
            case let .video(bytes, keyframe):
                decoder.decode(bytes, keyframe: keyframe, pts: now)
            case let .audio(bytes, codec):
                let pcm = G711.decode(bytes, codec: codec)
                audio.play(pcm)
                let recorder = lock.withLock { self.recorder }
                recorder?.appendAudio(pcm, pts: now)
            }
        }
    }

    // MARK: Recording

    func startRecording() -> ClipRecorder {
        let recorder = ClipRecorder()
        lock.withLock { self.recorder = recorder }
        return recorder
    }

    func stopRecording() -> ClipRecorder? {
        lock.withLock {
            let current = recorder
            recorder = nil
            return current
        }
    }

    // MARK: Snapshot

    func snapshot() -> UIImage? {
        guard let frame = lock.withLock({ latestFrame }) else { return nil }
        let image = CIImage(cvPixelBuffer: frame)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: Display

    private func show(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        lock.withLock { latestFrame = pixelBuffer }

        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return }
        SampleAttachments.set(sample, kCMSampleAttachmentKey_DisplayImmediately, true)

        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.videoView else { return }
            view.enqueue(sample)
            if size != self.lastSize {
                self.lastSize = size
                self.onVideoSize?(size)
            }
        }
    }
}
