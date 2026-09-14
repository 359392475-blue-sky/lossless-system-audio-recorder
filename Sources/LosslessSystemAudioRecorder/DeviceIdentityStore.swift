import Foundation
import CryptoKit
import Security
import IOKit

struct DeviceIdentity {
    let privateKey: Curve25519.Signing.PrivateKey
    let deviceHash: String
    var publicKey: String { privateKey.publicKey.rawRepresentation.base64EncodedString() }
}

@MainActor
protocol DeviceIdentityProviding {
    func identity() throws -> DeviceIdentity
}

/// Device identity is local and non-synchronizing. Raw hardware identifiers never leave this type.
@MainActor
final class DeviceIdentityStore: DeviceIdentityProviding {
    private let service = "app.lowpower.lossless-system-audio-recorder.referral"
    private let account = "device-signing-key-v1"
    private var cached: DeviceIdentity?

    func identity() throws -> DeviceIdentity {
        if let cached { return cached }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { throw PolicyFailure(message: "无法读取此 Mac 的设备标识，请重试。") }
        defer { IOObjectRelease(entry) }
        guard let raw = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              let uuid = UUID(uuidString: raw) else { throw PolicyFailure(message: "无法读取此 Mac 的设备标识，请重试。") }
        let hash = SHA256.hash(data: Data(("app.lowpower.lossless-system-audio-recorder:" + uuid.uuidString).utf8)).map { String(format: "%02x", $0) }.joined()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let result = SecItemCopyMatching(lookup as CFDictionary, &item)
        let key: Curve25519.Signing.PrivateKey
        if result == errSecSuccess, let data = item as? Data {
            do { key = try Curve25519.Signing.PrivateKey(rawRepresentation: data) }
            catch { throw PolicyFailure(message: "本机设备凭据损坏，无法验证试用资格。") }
        } else if result == errSecItemNotFound {
            key = Curve25519.Signing.PrivateKey()
            var insertion = query
            insertion[kSecValueData as String] = key.rawRepresentation
            insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let saved = SecItemAdd(insertion as CFDictionary, nil)
            guard saved == errSecSuccess else { throw PolicyFailure(message: "无法安全保存本机设备凭据，请重试。") }
        } else {
            throw PolicyFailure(message: "无法读取钥匙串中的设备凭据，请解锁钥匙串后重试。")
        }
        let identity = DeviceIdentity(privateKey: key, deviceHash: hash)
        cached = identity
        return identity
    }
}
