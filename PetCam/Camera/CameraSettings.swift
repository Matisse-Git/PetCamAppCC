import Foundation
import Security

enum StreamQuality: String, CaseIterable, Codable, Identifiable {
    case auto, hd, sd

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .hd: "HD"
        case .sd: "SD"
        }
    }

    var detail: String {
        switch self {
        case .auto: "HD on Wi-Fi, SD on cellular"
        case .hd: "Always the main stream"
        case .sd: "Always the low-data stream"
        }
    }
}

enum NightVisionMode: Int, CaseIterable, Identifiable {
    case auto = 0
    case off = 1
    case on = 2

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .auto: "Auto"
        case .off: "Off (color)"
        case .on: "On (infrared)"
        }
    }
}

/// Everything except the password, stored in UserDefaults.
struct CameraSettings: Codable, Equatable {
    var host: String = ""
    var username: String = "admin"
    var serial: String = ""
    var quality: StreamQuality = .auto
    var ptzSpeed: Int = 5
    var invertPan = false
    var invertTilt = false
    var soundOnLaunch = true

    var isConfigured: Bool { !host.isEmpty }

    private static let key = "PetCam.CameraSettings"

    static func load() -> CameraSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(CameraSettings.self, from: data) else { return CameraSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// The camera password lives only in the iPhone's Keychain.
enum Keychain {
    private static let service = "com.matissegit.petcam"
    private static let account = "camera-password"

    static var password: String {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data else { return "" }
            return String(decoding: data, as: UTF8.self)
        }
        set {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecValueData as String] = Data(newValue.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func deletePassword() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
