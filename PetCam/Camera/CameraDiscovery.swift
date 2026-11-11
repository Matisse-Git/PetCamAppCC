import Foundation
import Network

/// Finds the camera by trying TCP port 34567 on every address of its /24 network.
/// Unlike a broadcast search this also works through Tailscale while away from home.
enum CameraDiscovery {
    struct Found: Identifiable, Hashable {
        let host: String
        var serial: String = ""
        var model: String = ""
        var id: String { host }
    }

    static let defaultPrefix = "192.168.1"

    static func prefix(of host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count == 4, parts.allSatisfy({ Int($0) != nil }) else { return defaultPrefix }
        return parts.prefix(3).joined(separator: ".")
    }

    /// Every address in the /24 that accepts a connection on the DVRIP port.
    static func scan(prefix: String, timeout: TimeInterval = 1.5) async -> [String] {
        await withTaskGroup(of: String?.self) { group in
            var addresses = (1...254).map { "\(prefix).\($0)" }.makeIterator()
            var found: [String] = []
            for _ in 0..<48 {
                guard let host = addresses.next() else { break }
                group.addTask { await isOpen(host, timeout: timeout) ? host : nil }
            }
            while let result = await group.next() {
                if let result { found.append(result) }
                if let host = addresses.next() {
                    group.addTask { await isOpen(host, timeout: timeout) ? host : nil }
                }
            }
            return found.sorted { lastOctet($0) < lastOctet($1) }
        }
    }

    /// Scans and logs in to each candidate. With a known serial, returns only that camera.
    static func locate(near host: String, serial: String, username: String, password: String) async -> [Found] {
        let candidates = await scan(prefix: prefix(of: host))
        var cameras: [Found] = []
        for candidate in candidates {
            guard let client = try? await DVRIPClient.connect(host: candidate, username: username, password: password, timeout: 3) else {
                // Port is open but we couldn't log in (other device, or other password).
                if serial.isEmpty { cameras.append(Found(host: candidate)) }
                continue
            }
            let info = (try? await client.systemInfo()) ?? [:]
            client.close()
            let found = Found(
                host: candidate,
                serial: info["SerialNo"] as? String ?? "",
                model: info["HardWare"] as? String ?? ""
            )
            if serial.isEmpty || found.serial == serial {
                cameras.append(found)
            }
        }
        return cameras
    }

    private static func lastOctet(_ host: String) -> Int {
        Int(host.split(separator: ".").last ?? "") ?? 0
    }

    private static func isOpen(_ host: String, timeout: TimeInterval) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 34567, using: .tcp)
        let queue = DispatchQueue(label: "petcam.scan")
        let once = OnceFlag()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.fire() { connection.cancel(); continuation.resume(returning: true) }
                case .failed, .waiting, .cancelled:
                    if once.fire() { connection.cancel(); continuation.resume(returning: false) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.fire() { connection.cancel(); continuation.resume(returning: false) }
            }
        }
    }
}
