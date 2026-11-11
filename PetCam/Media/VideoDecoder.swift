import CoreMedia
import VideoToolbox

enum SampleAttachments {
    static func set(_ sample: CMSampleBuffer, _ key: CFString, _ value: Bool) {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
              CFArrayGetCount(array) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(array, 0), to: CFMutableDictionary.self)
        let cfValue: CFBoolean = value ? kCFBooleanTrue : kCFBooleanFalse
        CFDictionarySetValue(
            dict,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(cfValue).toOpaque()
        )
    }
}

/// Turns Annex-B H.264/H.265 access units into decoded pixel buffers with VideoToolbox.
/// Also hands out the compressed (length-prefixed) sample buffers for recording.
/// Not thread-safe: call `decode` from one serial queue.
final class VideoDecoder {
    enum Codec { case h264, hevc }

    /// Called on a VideoToolbox thread.
    var onDecoded: ((CVPixelBuffer, CMTime) -> Void)?
    /// Called synchronously from `decode` with the compressed frame.
    var onCompressed: ((CMSampleBuffer, Bool) -> Void)?

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var codec: Codec = .h264
    private var parameterSets: [[UInt8]] = []
    private var waitingForKeyframe = true

    deinit { invalidateSession() }

    func reset() {
        invalidateSession()
        formatDescription = nil
        parameterSets = []
        waitingForKeyframe = true
    }

    func decode(_ annexB: [UInt8], keyframe: Bool, pts: CMTime) {
        let nals = Self.nalUnits(annexB)
        guard !nals.isEmpty else { return }

        if keyframe { updateFormat(from: nals) }
        if waitingForKeyframe {
            guard keyframe, formatDescription != nil else { return }
            waitingForKeyframe = false
        }
        guard let format = formatDescription else { return }

        var avcc: [UInt8] = []
        avcc.reserveCapacity(annexB.count + 16)
        for nal in nals where !isParameterSetOrDelimiter(nal) {
            let n = UInt32(nal.count)
            avcc.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
            avcc.append(contentsOf: nal)
        }
        guard !avcc.isEmpty, let sample = Self.makeSample(avcc, format: format, pts: pts, keyframe: keyframe) else { return }

        onCompressed?(sample, keyframe)
        decompress(sample)
    }

    // MARK: Format

    private func updateFormat(from nals: [ArraySlice<UInt8>]) {
        let detected: Codec = nals.contains { $0.first == 0x40 } ? .hevc : .h264
        var sets: [[UInt8]] = []
        switch detected {
        case .h264:
            guard let sps = nals.first(where: { ($0.first ?? 0) & 0x1F == 7 }),
                  let pps = nals.first(where: { ($0.first ?? 0) & 0x1F == 8 }) else { return }
            sets = [Array(sps), Array(pps)]
        case .hevc:
            guard let vps = nals.first(where: { Self.hevcType($0) == 32 }),
                  let sps = nals.first(where: { Self.hevcType($0) == 33 }),
                  let pps = nals.first(where: { Self.hevcType($0) == 34 }) else { return }
            sets = [Array(vps), Array(sps), Array(pps)]
        }
        guard sets != parameterSets || detected != codec || formatDescription == nil else { return }
        guard let format = Self.makeFormat(sets, codec: detected) else { return }

        codec = detected
        parameterSets = sets
        formatDescription = format
        if let session, VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: format) {
            return
        }
        createSession(format)
    }

    private static func hevcType(_ nal: ArraySlice<UInt8>) -> UInt8 {
        ((nal.first ?? 0) >> 1) & 0x3F
    }

    private func isParameterSetOrDelimiter(_ nal: ArraySlice<UInt8>) -> Bool {
        guard let first = nal.first else { return true }
        switch codec {
        case .h264:
            let t = first & 0x1F
            return t == 7 || t == 8 || t == 9
        case .hevc:
            let t = (first >> 1) & 0x3F
            return t == 32 || t == 33 || t == 34 || t == 35
        }
    }

    private static func makeFormat(_ sets: [[UInt8]], codec: Codec) -> CMVideoFormatDescription? {
        let buffers: [UnsafeMutablePointer<UInt8>] = sets.map { set in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            p.initialize(from: set, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        let sizes: [Int] = sets.map(\.count)

        var format: CMFormatDescription?
        let status: OSStatus = pointers.withUnsafeBufferPointer { p in
            sizes.withUnsafeBufferPointer { s in
                switch codec {
                case .h264:
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: sets.count,
                        parameterSetPointers: p.baseAddress!,
                        parameterSetSizes: s.baseAddress!,
                        nalUnitHeaderLength: 4,
                        formatDescriptionOut: &format
                    )
                case .hevc:
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: sets.count,
                        parameterSetPointers: p.baseAddress!,
                        parameterSetSizes: s.baseAddress!,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &format
                    )
                }
            }
        }
        return status == noErr ? format : nil
    }

    // MARK: Decoding

    private func createSession(_ format: CMVideoFormatDescription) {
        invalidateSession()
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var newSession: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &newSession
        )
        if status == noErr { session = newSession }
    }

    private func invalidateSession() {
        if let session {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
    }

    private func decompress(_ sample: CMSampleBuffer) {
        guard let session else { return }
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sample,
            flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
            infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, pts, _ in
            guard status == noErr, let imageBuffer else { return }
            self?.onDecoded?(imageBuffer, pts)
        }
        if status == kVTInvalidSessionErr, let format = formatDescription {
            createSession(format)
            waitingForKeyframe = true
        }
    }

    // MARK: Helpers

    private static func makeSample(_ avcc: [UInt8], format: CMVideoFormatDescription, pts: CMTime, keyframe: Bool) -> CMSampleBuffer? {
        let length = avcc.count
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }

        let copied = avcc.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleSize = length
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sample
        ) == noErr, let sample else { return nil }

        SampleAttachments.set(sample, kCMSampleAttachmentKey_NotSync, !keyframe)
        return sample
    }

    /// Splits an Annex-B byte stream on 3- or 4-byte start codes.
    static func nalUnits(_ b: [UInt8]) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var i = 0
        var start = -1
        let n = b.count
        while i + 2 < n {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    while end > start, b[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(b[start..<end]) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < n { units.append(b[start..<n]) }
        return units
    }
}
