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
    /// The first "not valid" answer of the current run of them. One alone doesn't lock: it has to be repeated later.
    public var refusedAt: Date?
    /// When the server's "not valid" was confirmed and the app locked. The key stays, so a later check can unlock it again.
    public var revokedAt: Date?

    public init(key: String, instanceID: String, token: String, activatedAt: Date, lastValidatedAt: Date,
                refusedAt: Date? = nil, revokedAt: Date? = nil) {
        self.key = key
        self.instanceID = instanceID
        self.token = token
        self.activatedAt = activatedAt
        self.lastValidatedAt = lastValidatedAt
        self.refusedAt = refusedAt
        self.revokedAt = revokedAt
    }
}

/// Whether this Mac used CineNotch before it was paid. Decided once, at the first launch of a build with licensing on,
/// and kept: early users never pay.
public struct EarlyAccess: Codable, Equatable, Sendable {
    public var isEarlySupporter: Bool
    public var decidedAt: Date

    public init(isEarlySupporter: Bool, decidedAt: Date) {
        self.isEarlySupporter = isEarlySupporter
        self.decidedAt = decidedAt
    }
}

/// `load` returns nil only when nothing is stored. A Keychain that can't be read right now throws instead, so a paid Mac
/// isn't mistaken for an unpaid one.
public protocol LicenseStoring: Sendable {
    func load() throws -> StoredLicense?
    func save(_ license: StoredLicense) throws
    func clear()
    func loadEarlyAccess() throws -> EarlyAccess?
    func saveEarlyAccess(_ value: EarlyAccess) throws
}

/// The license in the macOS Keychain (generic password items), so deleting the app doesn't lose the activation.
public struct KeychainLicenseStore: LicenseStoring {
    public var service: String
    public var account: String

    public init(service: String = "com.cinenotch.CineNotch.license", account: String = "activation") {
        self.service = service
        self.account = account
    }

    public func load() throws -> StoredLicense? { try read(StoredLicense.self, account: account) }
    public func save(_ license: StoredLicense) throws { try write(license, account: account) }
    public func clear() { SecItemDelete(query(account) as CFDictionary) }

    public func loadEarlyAccess() throws -> EarlyAccess? { try read(EarlyAccess.self, account: "\(account).early-access") }
    public func saveEarlyAccess(_ value: EarlyAccess) throws { try write(value, account: "\(account).early-access") }
    /// Debug runs only (`--debug-license-reset`).
    public func clearEarlyAccess() { SecItemDelete(query("\(account).early-access") as CFDictionary) }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read<T: Decodable>(_ type: T.Type, account: String) throws -> T? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        // Damaged contents count as nothing stored: there's nothing to wait for.
        return try? decoder.decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, account: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(value)
        let status = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        var add = query(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
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
    private var early: EarlyAccess?
    /// Tests: how many more reads fail as if the Keychain were locked.
    public var failingReads = 0

    public init(_ value: StoredLicense? = nil, earlyAccess: EarlyAccess? = nil) {
        self.value = value
        early = earlyAccess
    }

    public func load() throws -> StoredLicense? { try lock.withLock { try failIfAsked(); return value } }
    public func save(_ license: StoredLicense) throws { lock.withLock { value = license } }
    public func clear() { lock.withLock { value = nil } }
    public func loadEarlyAccess() throws -> EarlyAccess? { try lock.withLock { try failIfAsked(); return early } }
    public func saveEarlyAccess(_ value: EarlyAccess) throws { lock.withLock { early = value } }

    private func failIfAsked() throws {
        guard failingReads > 0 else { return }
        failingReads -= 1
        throw KeychainError(status: errSecInteractionNotAllowed)
    }
}
