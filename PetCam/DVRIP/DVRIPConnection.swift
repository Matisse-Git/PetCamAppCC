import Foundation
import Network

/// Fires exactly once, from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false

    func fire() -> Bool {
        lock.withLock {
            if fired { return false }
            fired = true
            return true
        }
    }
}

/// One TCP connection speaking DVRIP framing: a 20-byte header followed by a payload.
/// JSON replies are matched to requests by message ID; video/audio chunks go to `onMedia`.
final class DVRIPConnection: @unchecked Sendable {
    typealias JSON = [String: Any]

    let host: String
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [UInt16: (token: Int, continuation: CheckedContinuation<JSON, Error>)] = [:]
    private var nextToken = 0
    private var sequence: UInt32 = 0
    private var session: UInt32 = 0
    private var isClosed = false
    private var didOpen = false

    /// Called on the connection's queue for every media chunk (message 1412). Set before `open()`.
    var onMedia: ((Data) -> Void)?
    /// Called once when the connection ends for any reason after it was opened.
    var onClose: ((Error?) -> Void)?

    var sessionID: UInt32 {
        get { lock.withLock { session } }
        set { lock.withLock { session = newValue } }
    }

    var sessionString: String { String(format: "0x%08X", sessionID) }

    init(host: String, port: UInt16 = 34567) {
        self.host = host
        queue = DispatchQueue(label: "petcam.dvrip.\(host)", qos: .userInitiated)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let params = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 34567,
            using: params
        )
    }

    deinit {
        connection.cancel()
    }

    // MARK: Opening

    func open(timeout: TimeInterval = 5) async throws {
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.fire() {
                        self?.lock.withLock { self?.didOpen = true }
                        continuation.resume()
                    }
                case .waiting(let error):
                    if once.fire() {
                        self?.connection.cancel()
                        continuation.resume(throwing: DVRIPError.unreachable(error.localizedDescription))
                    }
                case .failed(let error):
                    if once.fire() {
                        continuation.resume(throwing: DVRIPError.unreachable(error.localizedDescription))
                    } else {
                        self?.handleClose(error)
                    }
                case .cancelled:
                    if once.fire() {
                        continuation.resume(throwing: DVRIPError.closed)
                    } else {
                        self?.handleClose(nil)
                    }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if once.fire() {
                    self?.connection.cancel()
                    continuation.resume(throwing: DVRIPError.timeout)
                }
            }
        }
        readHeader()
    }

    func close() {
        handleClose(nil)
    }

    // MARK: Sending

    func send(_ messageID: UInt16, payload: Data) {
        let (seq, sid): (UInt32, UInt32) = lock.withLock {
            let current = (sequence, session)
            sequence &+= 1
            return current
        }
        var packet = Data(DVRIPHeader.encode(session: sid, sequence: seq, messageID: messageID, length: payload.count))
        packet.append(payload)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            if let error { self?.handleClose(error) }
        })
    }

    func sendJSON(_ messageID: UInt16, _ body: JSON) {
        guard var data = try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes]) else { return }
        data.append(contentsOf: [0x0A, 0x00])
        send(messageID, payload: data)
    }

    /// Sends a JSON request and waits for the reply with message ID `messageID + 1`.
    func request(_ messageID: UInt16, _ body: JSON, timeout: TimeInterval = 8) async throws -> JSON {
        let replyID = messageID &+ 1
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSON, Error>) in
            let token: Int? = lock.withLock {
                if isClosed { return nil }
                nextToken += 1
                if let previous = pending.removeValue(forKey: replyID) {
                    previous.continuation.resume(throwing: DVRIPError.timeout)
                }
                pending[replyID] = (nextToken, continuation)
                return nextToken
            }
            guard let token else {
                continuation.resume(throwing: DVRIPError.closed)
                return
            }
            sendJSON(messageID, body)
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self else { return }
                let expired: CheckedContinuation<JSON, Error>? = self.lock.withLock {
                    guard let entry = self.pending[replyID], entry.token == token else { return nil }
                    self.pending.removeValue(forKey: replyID)
                    return entry.continuation
                }
                expired?.resume(throwing: DVRIPError.timeout)
            }
        }
    }

    // MARK: Receiving

    private func readHeader() {
        connection.receive(minimumIncompleteLength: DVRIPHeader.size, maximumLength: DVRIPHeader.size) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.handleClose(error); return }
            guard let data, data.count == DVRIPHeader.size, let header = DVRIPHeader(data) else {
                self.handleClose(isComplete ? nil : DVRIPError.badResponse)
                return
            }
            guard header.length < 8_000_000 else { self.handleClose(DVRIPError.badResponse); return }
            if header.length == 0 {
                self.dispatch(header, Data())
                self.readHeader()
                return
            }
            self.readPayload(header)
        }
    }

    private func readPayload(_ header: DVRIPHeader) {
        let length = Int(header.length)
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error { self.handleClose(error); return }
            guard let data, data.count == length else {
                self.handleClose(isComplete ? nil : DVRIPError.badResponse)
                return
            }
            self.dispatch(header, data)
            self.readHeader()
        }
    }

    private func dispatch(_ header: DVRIPHeader, _ payload: Data) {
        if header.messageID == DVRIPMessage.monitorData {
            onMedia?(payload)
            return
        }
        guard let json = DVRIPConnection.decodeJSON(payload) else { return }
        let waiter: CheckedContinuation<JSON, Error>? = lock.withLock {
            pending.removeValue(forKey: header.messageID)?.continuation
        }
        waiter?.resume(returning: json)
    }

    static func decodeJSON(_ data: Data) -> JSON? {
        var bytes = [UInt8](data)
        while let last = bytes.last, last == 0 || last == 0x0A || last == 0x0D || last == 0x20 {
            bytes.removeLast()
        }
        guard !bytes.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(bytes))) as? JSON
    }

    private func handleClose(_ error: Error?) {
        let result: (waiters: [CheckedContinuation<JSON, Error>], notify: Bool)? = lock.withLock {
            if isClosed { return nil }
            isClosed = true
            let all = pending.values.map(\.continuation)
            pending.removeAll()
            return (all, didOpen)
        }
        guard let result else { return }
        connection.cancel()
        result.waiters.forEach { $0.resume(throwing: DVRIPError.closed) }
        if result.notify { onClose?(error) }
    }
}
