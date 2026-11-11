import Foundation
import CoreGraphics
import CryptoKit

/// Message IDs of the Xiongmai "DVRIP / Sofia" protocol (TCP port 34567).
/// A reply always uses the request ID + 1.
enum DVRIPMessage {
    static let login: UInt16 = 1000
    static let keepAlive: UInt16 = 1006
    static let systemInfo: UInt16 = 1020
    static let configSet: UInt16 = 1040
    static let configGet: UInt16 = 1042
    static let systemFunction: UInt16 = 1360
    static let ptzControl: UInt16 = 1400
    static let monitorStart: UInt16 = 1410
    static let monitorData: UInt16 = 1412
    static let monitorClaim: UInt16 = 1413
    static let talkStart: UInt16 = 1430
    static let talkData: UInt16 = 1432
    static let talkClaim: UInt16 = 1434
}

enum DVRIPError: LocalizedError, Equatable {
    case unreachable(String)
    case timeout
    case closed
    case badResponse
    case wrongPassword
    case accountLocked
    case failed(Int)

    var errorDescription: String? {
        switch self {
        case .unreachable(let reason): "Can't reach the camera (\(reason))."
        case .timeout: "The camera didn't respond in time."
        case .closed: "The connection to the camera closed."
        case .badResponse: "The camera sent a reply PetCam doesn't understand."
        case .wrongPassword: "Wrong camera username or password."
        case .accountLocked: "The camera locked this account after too many attempts. Wait a few minutes, or unplug it and plug it back in."
        case .failed(let code): "The camera refused the request (code \(code))."
        }
    }

    /// Maps a DVRIP "Ret" code to an error, or nil when the code means success.
    static func from(ret: Int) -> DVRIPError? {
        switch ret {
        case 100, 515: nil
        case 106, 203, 204: .wrongPassword
        case 205, 206: .accountLocked
        default: .failed(ret)
        }
    }
}

/// Xiongmai's password hash: MD5, then each pair of bytes folded into one of 62 characters.
enum SofiaHash {
    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    static func hash(_ password: String) -> String {
        let digest = Array(Insecure.MD5.hash(data: Data(password.utf8)))
        var out = ""
        for i in stride(from: 0, to: digest.count, by: 2) {
            out.append(alphabet[(Int(digest[i]) + Int(digest[i + 1])) % 62])
        }
        return out
    }
}

struct DVRIPHeader {
    static let size = 20
    let session: UInt32
    let sequence: UInt32
    let messageID: UInt16
    let length: UInt32

    init?(_ data: Data) {
        let b = [UInt8](data)
        guard b.count >= DVRIPHeader.size, b[0] == 0xFF else { return nil }
        session = Bytes.le32(b, 4)
        sequence = Bytes.le32(b, 8)
        messageID = Bytes.le16(b, 14)
        length = Bytes.le32(b, 16)
    }

    static func encode(session: UInt32, sequence: UInt32, messageID: UInt16, length: Int) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: size)
        b[0] = 0xFF
        Bytes.put32(&b, 4, session)
        Bytes.put32(&b, 8, sequence)
        b[14] = UInt8(messageID & 0xFF)
        b[15] = UInt8(messageID >> 8)
        Bytes.put32(&b, 16, UInt32(length))
        return b
    }
}

enum Bytes {
    static func le16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | UInt16(b[o + 1]) << 8
    }

    static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
    }

    static func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        b[o] = UInt8(v & 0xFF)
        b[o + 1] = UInt8((v >> 8) & 0xFF)
        b[o + 2] = UInt8((v >> 16) & 0xFF)
        b[o + 3] = UInt8((v >> 24) & 0xFF)
    }
}

/// Xiongmai configs mix hex strings ("0x00000002") and plain numbers.
enum HexInt {
    static func parse(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("0x") || t.hasPrefix("0X") { return Int(t.dropFirst(2), radix: 16) }
        return Int(t)
    }

    static func format(_ v: Int) -> String { String(format: "0x%08X", v) }

    /// Writes `value` into `dict[key]`, keeping whichever representation the camera used.
    static func set(_ dict: inout [String: Any], _ key: String, _ value: Int) {
        if dict[key] is String { dict[key] = format(value) } else { dict[key] = value }
    }
}

extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int? {
        switch self[key] {
        case let v as Int: v
        case let v as NSNumber: v.intValue
        case let v as String: HexInt.parse(v)
        default: nil
        }
    }

    func bool(_ key: String) -> Bool? {
        switch self[key] {
        case let v as Bool: v
        case let v as NSNumber: v.boolValue
        default: nil
        }
    }
}

enum PTZDirection: String, CaseIterable {
    case up = "DirectionUp"
    case down = "DirectionDown"
    case left = "DirectionLeft"
    case right = "DirectionRight"
    case upLeft = "DirectionLeftUp"
    case downLeft = "DirectionLeftDown"
    case upRight = "DirectionRightUp"
    case downRight = "DirectionRightDown"

    /// Direction for a 2D vector (screen coordinates, y grows downwards), or nil inside the dead zone.
    static func from(dx: CGFloat, dy: CGFloat, deadZone: CGFloat) -> PTZDirection? {
        guard hypot(dx, dy) >= deadZone else { return nil }
        var degrees = atan2(-dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        let sector = Int(((degrees + 22.5).truncatingRemainder(dividingBy: 360)) / 45)
        let order: [PTZDirection] = [.right, .upRight, .up, .upLeft, .left, .downLeft, .down, .downRight]
        return order[sector]
    }

    private var components: (x: Int, y: Int) {
        switch self {
        case .up: (0, 1)
        case .down: (0, -1)
        case .left: (-1, 0)
        case .right: (1, 0)
        case .upLeft: (-1, 1)
        case .downLeft: (-1, -1)
        case .upRight: (1, 1)
        case .downRight: (1, -1)
        }
    }

    private static func from(x: Int, y: Int) -> PTZDirection? {
        allCases.first { $0.components == (x, y) }
    }

    func adjusted(invertPan: Bool, invertTilt: Bool) -> PTZDirection {
        let c = components
        return PTZDirection.from(x: invertPan ? -c.x : c.x, y: invertTilt ? -c.y : c.y) ?? self
    }
}
