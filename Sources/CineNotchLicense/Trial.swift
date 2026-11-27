import Foundation
import Security

// The 7-day trial. A new Mac (not licensed, not an early supporter) gets every feature for 7 days from its first launch
// of a build with licensing on, then the usual soft lock. Nothing here touches the network. Like the license, it keeps
// honest people honest: the first-launch date is kept in the Keychain and mirrored in the defaults, so deleting one
// doesn't start it over, and moving the clock back doesn't add days. It is not DRM.

/// When this Mac's trial started, and the latest time the app saw. Both only ever move in the conservative direction:
/// the start never moves later, the last-seen never moves earlier.
public struct TrialRecord: Codable, Equatable, Sendable {
    public var startDate: Date
    public var lastSeenDate: Date

    public init(startDate: Date, lastSeenDate: Date) {
        self.startDate = startDate
        self.lastSeenDate = max(lastSeenDate, startDate)
    }
}

public enum TrialStatus: Equatable, Sendable {
    /// No trial here: licensing is off, the trial hasn't been read yet, or it doesn't apply to this Mac.
    case inactive
    /// `daysLeft` counts the started day: 7 on the first day, 1 on the last.
    case active(daysLeft: Int)
    case expired

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    public var isExpired: Bool { self == .expired }

    /// "7 days left", "1 day left". Nil unless active.
    public var daysLeftText: String? {
        guard case .active(let days) = self else { return nil }
        return days == 1 ? "1 day left" : "\(days) days left"
    }
}

/// The trial's arithmetic, with no clock or storage of its own.
public enum TrialClock {
    public static let duration: TimeInterval = 7 * 24 * 3600
    static let day: TimeInterval = 24 * 3600

    /// Days are counted from `max(now, lastSeen)`, so a clock set back never gives days back. A clock set to before the
    /// start counts as the last time seen: the original window stays, nothing starts over.
    public static func status(of record: TrialRecord, now: Date) -> TrialStatus {
        let effective = max(now, record.lastSeenDate)
        let elapsed = max(0, effective.timeIntervalSince(record.startDate))
        let remaining = duration - elapsed
        guard remaining > 0 else { return .expired }
        return .active(daysLeft: Int((remaining / day).rounded(.up)))
    }

    /// The record after a look at the clock: last-seen moves forward, never back.
    public static func touched(_ record: TrialRecord, now: Date) -> TrialRecord {
        TrialRecord(startDate: record.startDate, lastSeenDate: max(record.lastSeenDate, now))
    }

    /// Two copies that disagree: the earlier start and the later last-seen win.
    public static func merge(_ a: TrialRecord, _ b: TrialRecord) -> TrialRecord {
        TrialRecord(startDate: min(a.startDate, b.startDate), lastSeenDate: max(a.lastSeenDate, b.lastSeenDate))
    }

    public static func merge(_ records: [TrialRecord]) -> TrialRecord? {
        guard let first = records.first else { return nil }
        return records.dropFirst().reduce(first) { merge($0, $1) }
    }
}

/// Whether the trial unlocks anything, given the license. Only a Mac that was never activated can be in a trial:
/// licensed and early-supporter Macs are unlocked anyway, a revoked or damaged license stays locked whatever the trial says.
public enum TrialAccess {
    public static func appliesTo(_ state: LicenseState) -> Bool {
        state == .unlicensed(.never)
    }

    /// What gates the core features.
    public static func isUnlocked(_ state: LicenseState, trial: TrialStatus) -> Bool {
        state.isUnlocked || appliesTo(state) && trial.isActive
    }

    /// The trial as the UI should show it: inactive unless this Mac was never activated.
    public static func visibleStatus(_ state: LicenseState, trial: TrialStatus) -> TrialStatus {
        appliesTo(state) ? trial : .inactive
    }
}

// MARK: Storage

/// `load` returns nil only when nothing is stored; a store that can't be read right now throws.
public protocol TrialStoring: AnyObject {
    func load() throws -> TrialRecord?
    func save(_ record: TrialRecord) throws
    func clear()
}

/// The record as a Keychain generic password (same service and accessibility as the license).
public final class KeychainTrialStore: TrialStoring {
    public let service: String
    public let account: String

    public init(service: String = "com.cinenotch.CineNotch.license", account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() throws -> TrialRecord? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(TrialRecord.self, from: data)
    }

    public func save(_ record: TrialRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(record)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(add as CFDictionary, nil)
        guard added == errSecSuccess else { throw KeychainError(status: added) }
    }

    public func clear() { SecItemDelete(query as CFDictionary) }
}

/// The record as two dates in the defaults.
public final class DefaultsTrialStore: TrialStoring {
    public let defaults: UserDefaults
    public let startKey: String
    public let lastSeenKey: String

    public init(defaults: UserDefaults = .standard, startKey: String, lastSeenKey: String) {
        self.defaults = defaults
        self.startKey = startKey
        self.lastSeenKey = lastSeenKey
    }

    private func date(_ key: String) -> Date? {
        switch defaults.object(forKey: key) {
        case let date as Date: return date
        case let seconds as Double: return Date(timeIntervalSince1970: seconds)
        default: return nil
        }
    }

    public func load() throws -> TrialRecord? {
        switch (date(startKey), date(lastSeenKey)) {
        case let (start?, seen?): return TrialRecord(startDate: start, lastSeenDate: seen)
        case let (start?, nil): return TrialRecord(startDate: start, lastSeenDate: start)
        // A last-seen without its start was edited: assume the trial is used up rather than give days.
        case let (nil, seen?): return TrialRecord(startDate: seen.addingTimeInterval(-TrialClock.duration), lastSeenDate: seen)
        case (nil, nil): return nil
        }
    }

    public func save(_ record: TrialRecord) throws {
        defaults.set(record.startDate, forKey: startKey)
        defaults.set(record.lastSeenDate, forKey: lastSeenKey)
    }

    public func clear() {
        defaults.removeObject(forKey: startKey)
        defaults.removeObject(forKey: lastSeenKey)
    }
}

/// Several copies of the record (the Keychain and the defaults). Reading merges whatever can be read, conservatively;
/// saving merges with what each copy already holds, so no copy's start moves later or its last-seen earlier, and a copy
/// that can't be read right now is left alone (it could hold an earlier start).
public final class MirroredTrialStore: TrialStoring {
    public let stores: [TrialStoring]

    public init(_ stores: [TrialStoring]) { self.stores = stores }

    /// The Keychain item `<account>.trial` and its mirror in the defaults. The real activation account and the debug one
    /// get separate keys, so a debug run never touches a real trial.
    public static func keychainAndDefaults(account: String, defaults: UserDefaults = .standard) -> MirroredTrialStore {
        let prefix: String
        switch account {
        case "activation": prefix = "CNTrial"
        case "debug-activation": prefix = "CNDebugTrial"
        default: prefix = "CNTrial.\(account)."
        }
        return MirroredTrialStore([
            KeychainTrialStore(account: "\(account).trial"),
            DefaultsTrialStore(defaults: defaults, startKey: "\(prefix)Start", lastSeenKey: "\(prefix)LastSeen"),
        ])
    }

    public func load() throws -> TrialRecord? {
        var found: [TrialRecord] = []
        var failure: Error?
        for store in stores {
            do {
                if let record = try store.load() { found.append(record) }
            } catch {
                failure = error
            }
        }
        if let merged = TrialClock.merge(found) { return merged }
        // Nothing readable says there's no trial, but a copy that couldn't be read might: wait for it.
        if let failure { throw failure }
        return nil
    }

    public func save(_ record: TrialRecord) throws {
        var wrote = false
        var failure: Error?
        for store in stores {
            do {
                let existing = try store.load()
                let merged = existing.map { TrialClock.merge($0, record) } ?? record
                if merged != existing { try store.save(merged) }
                wrote = true
            } catch {
                failure = error
            }
        }
        if !wrote, let failure { throw failure }
    }

    public func clear() { stores.forEach { $0.clear() } }
}

/// For tests and `--debug-license-state`: nothing touches the Keychain or the defaults.
public final class MemoryTrialStore: TrialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TrialRecord?
    /// Tests: how many more reads fail as if the Keychain were locked.
    public var failingReads = 0
    public private(set) var saves = 0

    public init(_ value: TrialRecord? = nil) { self.value = value }

    public var record: TrialRecord? { lock.withLock { value } }

    public func load() throws -> TrialRecord? {
        try lock.withLock {
            if failingReads > 0 {
                failingReads -= 1
                throw KeychainError(status: errSecInteractionNotAllowed)
            }
            return value
        }
    }

    public func save(_ record: TrialRecord) throws { lock.withLock { value = record; saves += 1 } }
    public func clear() { lock.withLock { value = nil } }
}

// MARK: Manager

/// Records the first launch once, moves last-seen forward while the app runs, and publishes the status.
/// The app starts it only for a Mac where licensing is on and that was never activated (see `TrialAccess`); until then,
/// and with licensing off, it does nothing and reads or writes nothing.
@MainActor
public final class TrialManager: ObservableObject {
    /// Where "Buy license" goes from the trial and after it.
    public static let buyURL = URL(string: "https://cinenotch.cam/?ref=trial")!
    static let refreshEvery: TimeInterval = 15 * 60

    @Published public private(set) var status: TrialStatus = .inactive
    public private(set) var isStarted = false

    private let store: TrialStoring
    private let now: () -> Date
    /// `--debug-trial-days-left`: the status is pinned and the store is never touched.
    private let fixedDaysLeft: Int?
    private var record: TrialRecord?
    private var timer: Timer?
    private var retries = 0

    public init(store: TrialStoring, now: @escaping () -> Date = Date.init, fixedDaysLeft: Int? = nil) {
        self.store = store
        self.now = now
        self.fixedDaysLeft = fixedDaysLeft
    }

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        if let fixedDaysLeft {
            status = fixedDaysLeft > 0 ? .active(daysLeft: fixedDaysLeft) : .expired
            LicenseLog.write("trial: pinned to \(status)")
            return
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: Self.refreshEvery, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 60
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads the record (creating it on the first launch), moves last-seen forward, writes it back to every copy.
    public func refresh() {
        guard isStarted, fixedDaysLeft == nil else { return }
        let n = now()
        let stored: TrialRecord?
        do {
            stored = try store.load()
        } catch {
            // Never read as "no trial yet": that would start a new one. Stay as we are and try again shortly.
            LicenseLog.write("trial: not readable (\(error)), trying again")
            retryShortly()
            return
        }
        retries = 0
        let known = [stored, record].compactMap { $0 }
        let isNew = known.isEmpty
        let base = TrialClock.merge(known) ?? TrialRecord(startDate: n, lastSeenDate: n)
        let updated = TrialClock.touched(base, now: n)
        // Always written: a copy that was deleted or disagrees gets the merged values back.
        try? store.save(updated)
        record = updated
        let next = TrialClock.status(of: updated, now: n)
        if isNew { LicenseLog.write("trial: started") }
        if next != status, next == .expired { LicenseLog.write("trial: ended") }
        status = next
    }

    private func retryShortly() {
        guard retries < 20 else { return }
        retries += 1
        let delay = min(5 * Double(retries), 60)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.refresh()
        }
    }
}
