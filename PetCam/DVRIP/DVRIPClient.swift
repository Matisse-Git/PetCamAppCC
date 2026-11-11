import Foundation

/// Serialises async work: one holder at a time, FIFO.
actor AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

enum StreamType {
    case main, sub

    var dvripName: String {
        switch self {
        case .main: "Main"
        case .sub: "Extra1"
        }
    }
}

/// A logged-in DVRIP session on one TCP connection.
final class DVRIPClient: @unchecked Sendable {
    typealias JSON = [String: Any]

    let connection: DVRIPConnection
    private let username: String
    private let password: String
    private let requestLock = AsyncLock()
    private var keepAliveTask: Task<Void, Never>?

    var host: String { connection.host }

    private init(host: String, username: String, password: String) {
        connection = DVRIPConnection(host: host)
        self.username = username
        self.password = password
    }

    deinit {
        keepAliveTask?.cancel()
    }

    /// Opens a connection and logs in. `onMedia` receives raw media chunks once a stream is started.
    static func connect(
        host: String,
        username: String,
        password: String,
        timeout: TimeInterval = 5,
        onMedia: ((Data) -> Void)? = nil,
        onClose: ((Error?) -> Void)? = nil
    ) async throws -> DVRIPClient {
        let client = DVRIPClient(host: host, username: username, password: password)
        client.connection.onMedia = onMedia
        client.connection.onClose = onClose
        try await client.connection.open(timeout: timeout)
        do {
            try await client.login()
        } catch {
            client.connection.onClose = nil
            client.close()
            throw error
        }
        return client
    }

    func close() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        connection.close()
    }

    // MARK: Session

    private func login() async throws {
        let reply = try await request(DVRIPMessage.login, [
            "EncryptType": "MD5",
            "LoginType": "DVRIP-Web",
            "PassWord": SofiaHash.hash(password),
            "UserName": username,
        ])
        if let error = DVRIPError.from(ret: reply.int("Ret") ?? -1) { throw error }
        if let sid = reply["SessionID"] as? String, let value = HexInt.parse(sid) {
            connection.sessionID = UInt32(truncatingIfNeeded: value)
        }
        let interval = max(6, min(reply.int("AliveInterval") ?? 20, 60))
        startKeepAlive(every: interval / 2)
    }

    private func startKeepAlive(every seconds: Int) {
        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                self.connection.sendJSON(DVRIPMessage.keepAlive, [
                    "Name": "KeepAlive",
                    "SessionID": self.connection.sessionString,
                ])
            }
        }
    }

    func request(_ messageID: UInt16, _ body: JSON, timeout: TimeInterval = 8) async throws -> JSON {
        await requestLock.lock()
        do {
            let reply = try await connection.request(messageID, body, timeout: timeout)
            await requestLock.unlock()
            return reply
        } catch {
            await requestLock.unlock()
            throw error
        }
    }

    @discardableResult
    func command(_ name: String, id: UInt16, _ params: JSON) async throws -> JSON {
        let reply = try await request(id, ["Name": name, "SessionID": connection.sessionString, name: params])
        if let error = DVRIPError.from(ret: reply.int("Ret") ?? -1) { throw error }
        return reply
    }

    // MARK: Info & config

    func systemInfo() async throws -> JSON {
        let reply = try await request(DVRIPMessage.systemInfo, ["Name": "SystemInfo", "SessionID": connection.sessionString])
        if let error = DVRIPError.from(ret: reply.int("Ret") ?? -1) { throw error }
        return reply["SystemInfo"] as? JSON ?? [:]
    }

    /// Reads a config such as "Camera.Param.[0]". Returns the object for that channel.
    func getConfig(_ name: String) async throws -> JSON {
        let reply = try await request(DVRIPMessage.configGet, ["Name": name, "SessionID": connection.sessionString])
        if let error = DVRIPError.from(ret: reply.int("Ret") ?? -1) { throw error }
        if let value = reply[name] as? JSON { return value }
        // Some firmwares answer "Camera.Param" with an array instead of "Camera.Param.[0]".
        let base = name.replacingOccurrences(of: ".[0]", with: "")
        if let list = reply[base] as? [JSON], let first = list.first { return first }
        if let value = reply[base] as? JSON { return value }
        throw DVRIPError.badResponse
    }

    func setConfig(_ name: String, _ value: JSON) async throws {
        let reply = try await request(DVRIPMessage.configSet, ["Name": name, "SessionID": connection.sessionString, name: value])
        if let error = DVRIPError.from(ret: reply.int("Ret") ?? -1) { throw error }
    }

    // MARK: Pan / tilt

    /// Starts (`moving: true`) or stops a continuous movement.
    func ptz(_ direction: PTZDirection, moving: Bool, speed: Int) async throws {
        let parameter: JSON = [
            "AUX": ["Number": 0, "Status": "On"],
            "Channel": 0,
            "MenuOpts": "Enter",
            "POINT": ["bottom": 0, "left": 0, "right": 0, "top": 0],
            "Pattern": "SetBegin",
            "Preset": moving ? 65535 : -1,
            "Step": max(1, min(speed, 8)),
            "Tour": 0,
        ]
        try await command("OPPTZControl", id: DVRIPMessage.ptzControl, ["Command": direction.rawValue, "Parameter": parameter])
    }

    // MARK: Live stream

    func startMonitor(_ stream: StreamType) async throws {
        let params: JSON = ["Channel": 0, "CombinMode": "NONE", "StreamType": stream.dvripName, "TransMode": "TCP"]
        try await command("OPMonitor", id: DVRIPMessage.monitorClaim, ["Action": "Claim", "Parameter": params])
        connection.sendJSON(DVRIPMessage.monitorStart, [
            "Name": "OPMonitor",
            "SessionID": connection.sessionString,
            "OPMonitor": ["Action": "Start", "Parameter": params],
        ])
    }

    // MARK: Talk (phone → camera speaker)

    private static let talkFormat: JSON = ["EncodeType": "G711_ALAW"]

    func startTalk() async throws {
        try await command("OPTalk", id: DVRIPMessage.talkClaim, ["Action": "Claim", "AudioFormat": Self.talkFormat])
        connection.sendJSON(DVRIPMessage.talkStart, [
            "Name": "OPTalk",
            "SessionID": connection.sessionString,
            "OPTalk": ["Action": "Start", "AudioFormat": Self.talkFormat],
        ])
    }

    /// Sends one chunk of G.711 A-law audio (8 kHz mono), normally 320 bytes = 40 ms.
    func sendTalkAudio(_ alaw: [UInt8]) {
        var packet: [UInt8] = [0x00, 0x00, 0x01, 0xFA, 0x0E, 0x02, UInt8(alaw.count & 0xFF), UInt8((alaw.count >> 8) & 0xFF)]
        packet.append(contentsOf: alaw)
        connection.send(DVRIPMessage.talkData, payload: Data(packet))
    }

    func stopTalk() {
        connection.sendJSON(DVRIPMessage.talkStart, [
            "Name": "OPTalk",
            "SessionID": connection.sessionString,
            "OPTalk": ["Action": "Stop", "AudioFormat": Self.talkFormat],
        ])
    }
}
