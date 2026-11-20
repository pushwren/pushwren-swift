import Foundation
import os
import Security

/// Where the device ID and its secret live between launches.
protocol IdentityStore: Sendable {
    func load() -> (deviceID: String, secret: String?)?
    func save(deviceID: String, secret: String?)
    func reset()
}

/// The Keychain: this device only, readable after the first unlock (spec section 8). Items
/// survive the app being deleted and reinstalled, so a reinstall keeps its device record.
struct KeychainIdentityStore: IdentityStore {
    static let service = "com.pushwren.sdk"

    func load() -> (deviceID: String, secret: String?)? {
        guard let deviceID = read("deviceID") else { return nil }
        return (deviceID, read("deviceSecret"))
    }

    func save(deviceID: String, secret: String?) {
        write("deviceID", deviceID)
        if let secret { write("deviceSecret", secret) } else { delete("deviceSecret") }
    }

    func reset() {
        delete("deviceID")
        delete("deviceSecret")
    }

    private func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func read(_ account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status != errSecSuccess && status != errSecItemNotFound { Log.error("Keychain read failed: \(status)") }
        return (out as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    private func write(_ account: String, _ value: String) {
        let data = Data(value.utf8)
        let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard update == errSecItemNotFound else {
            if update != errSecSuccess { Log.error("Keychain update failed: \(update)") }
            return
        }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { Log.error("Keychain write failed: \(status)") }
    }

    private func delete(_ account: String) {
        let status = SecItemDelete(base(account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { Log.error("Keychain delete failed: \(status)") }
    }
}

/// An identity kept in memory only, for tests.
final class MemoryIdentityStore: IdentityStore {
    private let state = OSAllocatedUnfairLock<(deviceID: String, secret: String?)?>(initialState: nil)

    func load() -> (deviceID: String, secret: String?)? { state.withLock { $0 } }
    func save(deviceID: String, secret: String?) { state.withLock { $0 = (deviceID, secret) } }
    func reset() { state.withLock { $0 = nil } }
}
