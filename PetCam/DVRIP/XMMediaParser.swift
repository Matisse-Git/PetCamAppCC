import Foundation

enum MediaFrame {
    /// Annex-B H.264/H.265 access unit.
    case video(bytes: [UInt8], keyframe: Bool)
    /// G.711 audio; `codec` is Xiongmai's codec byte (0x0E = A-law, 0x0A = µ-law).
    case audio(bytes: [UInt8], codec: UInt8)
}

/// Splits the DVRIP media stream into frames. Frames can span several DVRIP chunks
/// and one chunk can hold several frames, so data is buffered until a frame is complete.
///
/// Frame headers (little endian):
/// - `00 00 01 FC` I-frame: codec, fps, width/8, height/8, 4-byte time, 4-byte length (16 bytes)
/// - `00 00 01 FD` P-frame: 4-byte length (8 bytes)
/// - `00 00 01 FA` audio: codec, rate, 2-byte length (8 bytes)
/// - `00 00 01 F9` info: type, ?, 2-byte length (8 bytes)
final class XMMediaParser {
    private var buffer: [UInt8] = []

    func reset() { buffer.removeAll(keepingCapacity: true) }

    func push(_ data: Data, emit: (MediaFrame) -> Void) {
        buffer.append(contentsOf: data)
        var offset = 0

        parse: while buffer.count - offset >= 8 {
            let o = offset
            guard isFrameStart(o) else {
                if let next = nextFrameStart(after: o) {
                    offset = next
                    continue parse
                }
                offset = max(o, buffer.count - 3)
                break parse
            }

            let type = buffer[o + 3]
            let headerSize: Int
            let bodySize: Int
            switch type {
            case 0xFC, 0xFE:
                guard buffer.count - o >= 16 else { break parse }
                headerSize = 16
                bodySize = Int(Bytes.le32(buffer, o + 12))
            case 0xFD:
                headerSize = 8
                bodySize = Int(Bytes.le32(buffer, o + 4))
            case 0xFA, 0xF9:
                headerSize = 8
                bodySize = Int(Bytes.le16(buffer, o + 6))
            default:
                offset = o + 4
                continue parse
            }

            guard bodySize < 4_000_000 else {
                offset = o + 4
                continue parse
            }
            let total = headerSize + bodySize
            guard buffer.count - o >= total else { break parse }

            let body = Array(buffer[(o + headerSize)..<(o + total)])
            switch type {
            case 0xFC, 0xFE:
                emit(.video(bytes: body, keyframe: true))
            case 0xFD:
                emit(.video(bytes: body, keyframe: false))
            case 0xFA:
                emit(.audio(bytes: body, codec: buffer[o + 4]))
            default:
                break
            }
            offset = o + total
        }

        if offset > 0 {
            buffer.removeFirst(min(offset, buffer.count))
        }
        if buffer.count > 8_000_000 { buffer.removeAll() }
    }

    private func isFrameStart(_ i: Int) -> Bool {
        guard i + 3 < buffer.count else { return false }
        return buffer[i] == 0 && buffer[i + 1] == 0 && buffer[i + 2] == 1 && Self.frameTypes.contains(buffer[i + 3])
    }

    private func nextFrameStart(after i: Int) -> Int? {
        var j = i + 1
        while j + 3 < buffer.count {
            if isFrameStart(j) { return j }
            j += 1
        }
        return nil
    }

    private static let frameTypes: Set<UInt8> = [0xF9, 0xFA, 0xFC, 0xFD, 0xFE]
}
