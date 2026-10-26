import Foundation
import Security

/// What stays on this Mac once it's activated.
public struct StoredLicense: Codable, Equatable, Sendable {
    public var key: String
    public var instanceID: String
    public var token: String
    public var activatedAt: Date
    /// The last time the server confirmed the license. Offline time since then is the grace period.
    public var lastValidatedAt: Date
}

public protocol LicenseStoring: Sendable {
    func load() -> StoredLicense?
    func save(_ license: StoredLicense) throws
    func clear()
}

/// The license in the macOS Keychain (a generic password item), so deleting the app doesn't lose the activation.
public struct KeychainLicenseStore: LicenseStoring {
    public var service: String
    public var account: String

    public init(service: String = "com.cinenotch.CineNotch.license", account: String = "activation") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> StoredLicense? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(StoredLicense.self, from: data)
    }

    public func save(_ license: StoredLicense) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(license)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public var status: OSStatus
    public var description: String { "Keychain error \(status)" }
}

/// For tests and `--debug-license-state`: nothing touches the Keychain.
public final class MemoryLicenseStore: LicenseStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredLicense?
    public init(_ value: StoredLicense? = nil) { self.value = value }
    public func load() -> StoredLicense? { lock.withLock { value } }
    public func save(_ license: StoredLicense) throws { lock.withLock { value = license } }
    public func clear() { lock.withLock { value = nil } }
}
