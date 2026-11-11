import Foundation

/// G.711 A-law / µ-law, as used by the camera's microphone and speaker.
enum G711 {
    static let alawCodec: UInt8 = 0x0E
    static let ulawCodec: UInt8 = 0x0A

    private static let alawTable: [Int16] = (0...255).map { alawToLinear(UInt8($0)) }
    private static let ulawTable: [Int16] = (0...255).map { ulawToLinear(UInt8($0)) }

    static func decode(_ bytes: [UInt8], codec: UInt8) -> [Int16] {
        let table = codec == ulawCodec ? ulawTable : alawTable
        return bytes.map { table[Int($0)] }
    }

    private static func alawToLinear(_ value: UInt8) -> Int16 {
        let a = value ^ 0x55
        var t = Int(a & 0x0F) << 4
        let segment = Int(a & 0x70) >> 4
        switch segment {
        case 0: t += 8
        case 1: t += 0x108
        default:
            t += 0x108
            t <<= segment - 1
        }
        return Int16((a & 0x80) != 0 ? t : -t)
    }

    private static func ulawToLinear(_ value: UInt8) -> Int16 {
        let u = ~value
        var t = (Int(u & 0x0F) << 3) + 0x84
        t <<= Int(u & 0x70) >> 4
        return Int16((u & 0x80) != 0 ? (0x84 - t) : (t - 0x84))
    }

    private static let segmentEnds: [Int] = [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF]

    static func alawEncode(_ sample: Int16) -> UInt8 {
        var pcm = Int(sample) >> 3
        let mask: Int
        if pcm >= 0 {
            mask = 0xD5
        } else {
            mask = 0x55
            pcm = -pcm - 1
        }
        guard let segment = segmentEnds.firstIndex(where: { pcm <= $0 }) else {
            return UInt8(0x7F ^ mask)
        }
        var value = segment << 4
        value |= segment < 2 ? (pcm >> 1) & 0x0F : (pcm >> segment) & 0x0F
        return UInt8((value ^ mask) & 0xFF)
    }
}
