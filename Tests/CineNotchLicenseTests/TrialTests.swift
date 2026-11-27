import XCTest
@testable import CineNotchLicense

/// The 7-day trial: day math, the clock set back, the two copies of the record, and the license winning over it.
/// Everything here is in memory (clock, stores): no Keychain, no network.
private let hour: TimeInterval = 3600
private let day: TimeInterval = 86400
/// 2026-11-01T12:00:00Z
private let t0 = Date(timeIntervalSince1970: 1_793_534_400)

private final class Clock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

final class TrialClockTests: XCTestCase {
    private func status(after elapsed: TimeInterval) -> TrialStatus {
        TrialClock.status(of: TrialRecord(startDate: t0, lastSeenDate: t0), now: t0.addingTimeInterval(elapsed))
    }

    func testDayMath() {
        XCTAssertEqual(status(after: 0), .active(daysLeft: 7), "first launch")
        XCTAssertEqual(status(after: day - 1), .active(daysLeft: 7), "just under 24h")
        XCTAssertEqual(status(after: day), .active(daysLeft: 6), "at 24h")
        XCTAssertEqual(status(after: day + 1), .active(daysLeft: 6))
        for n in 0..<7 {
            XCTAssertEqual(status(after: Double(n) * day), .active(daysLeft: 7 - n), "after \(n) full days")
        }
        XCTAssertEqual(status(after: 6 * day), .active(daysLeft: 1), "the last day")
        XCTAssertEqual(status(after: 7 * day - 1), .active(daysLeft: 1), "the last second of the last day")
        XCTAssertEqual(status(after: 7 * day), .expired, "at exactly 7*24h")
        XCTAssertEqual(status(after: 7 * day + 1), .expired)
        XCTAssertEqual(status(after: 400 * day), .expired)
    }

    func testDaysLeftText() {
        XCTAssertEqual(TrialStatus.active(daysLeft: 7).daysLeftText, "7 days left")
        XCTAssertEqual(TrialStatus.active(daysLeft: 2).daysLeftText, "2 days left")
        XCTAssertEqual(TrialStatus.active(daysLeft: 1).daysLeftText, "1 day left")
        XCTAssertNil(TrialStatus.expired.daysLeftText)
        XCTAssertNil(TrialStatus.inactive.daysLeftText)
    }

    func testExpiryIsAHardStop() {
        let expired = status(after: 7 * day)
        XCTAssertFalse(expired.isActive)
        XCTAssertTrue(expired.isExpired)
        XCTAssertFalse(TrialAccess.isUnlocked(.unlicensed(.never), trial: expired))
    }

    func testClockSetBackDoesNotGiveDaysBack() {
        // Used for 3.5 days, then the clock goes back two days.
        let record = TrialRecord(startDate: t0, lastSeenDate: t0.addingTimeInterval(3.5 * day))
        XCTAssertEqual(TrialClock.status(of: record, now: record.lastSeenDate), .active(daysLeft: 4))
        XCTAssertEqual(TrialClock.status(of: record, now: t0.addingTimeInterval(1.5 * day)), .active(daysLeft: 4))
        // Last-seen never moves back.
        XCTAssertEqual(TrialClock.touched(record, now: t0), record)
    }

    func testClockSetBeforeTheStartDoesNotStartOver() {
        let record = TrialRecord(startDate: t0, lastSeenDate: t0.addingTimeInterval(6.5 * day))
        let status = TrialClock.status(of: record, now: t0.addingTimeInterval(-30 * day))
        XCTAssertEqual(status, .active(daysLeft: 1))
        let expired = TrialRecord(startDate: t0, lastSeenDate: t0.addingTimeInterval(8 * day))
        XCTAssertEqual(TrialClock.status(of: expired, now: t0.addingTimeInterval(-30 * day)), .expired)
    }

    func testMergeIsConservative() {
        let a = TrialRecord(startDate: t0, lastSeenDate: t0.addingTimeInterval(day))
        let b = TrialRecord(startDate: t0.addingTimeInterval(2 * day), lastSeenDate: t0.addingTimeInterval(3 * day))
        let merged = TrialClock.merge(a, b)
        XCTAssertEqual(merged.startDate, t0)
        XCTAssertEqual(merged.lastSeenDate, t0.addingTimeInterval(3 * day))
        XCTAssertEqual(TrialClock.merge(b, a), merged)
        XCTAssertNil(TrialClock.merge([]))
    }
}

final class TrialAccessTests: XCTestCase {
    private let licensed = LicenseState.licensed(LicenseSummary(keyHint: "…ABCD", activatedAt: t0, lastValidatedAt: t0, needsReconnect: false))
    private let early = LicenseState.earlySupporter(since: t0)

    func testTrialUnlocksOnlyANeverActivatedMac() {
        XCTAssertTrue(TrialAccess.isUnlocked(.unlicensed(.never), trial: .active(daysLeft: 3)))
        XCTAssertFalse(TrialAccess.isUnlocked(.unlicensed(.never), trial: .expired))
        XCTAssertFalse(TrialAccess.isUnlocked(.unlicensed(.never), trial: .inactive))
        XCTAssertFalse(TrialAccess.isUnlocked(.unlicensed(.revoked), trial: .active(daysLeft: 5)), "revoked stays locked")
        XCTAssertFalse(TrialAccess.isUnlocked(.unlicensed(.storedInvalid), trial: .active(daysLeft: 5)), "damaged stays locked")
    }

    func testLicenseWinsOverTheTrial() {
        for state in [licensed, early, LicenseState.off] {
            for trial in [TrialStatus.inactive, .active(daysLeft: 2), .expired] {
                XCTAssertTrue(TrialAccess.isUnlocked(state, trial: trial), "\(state) \(trial)")
                XCTAssertEqual(TrialAccess.visibleStatus(state, trial: trial), .inactive, "no trial UI for \(state)")
            }
        }
        for reason in [UnlicensedReason.revoked, .storedInvalid] {
            XCTAssertEqual(TrialAccess.visibleStatus(.unlicensed(reason), trial: .active(daysLeft: 2)), .inactive)
            XCTAssertFalse(TrialAccess.appliesTo(.unlicensed(reason)))
        }
        XCTAssertEqual(TrialAccess.visibleStatus(.unlicensed(.never), trial: .active(daysLeft: 2)), .active(daysLeft: 2))
        // The license's own answer doesn't change because of a trial.
        XCTAssertFalse(LicenseState.unlicensed(.never).isUnlocked)
    }
}

final class TrialStoreTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults().removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    private func defaultsStore() -> DefaultsTrialStore {
        let name = "cinenotch.trial.tests.\(UUID().uuidString)"
        suites.append(name)
        return DefaultsTrialStore(defaults: UserDefaults(suiteName: name)!, startKey: "CNTrialStart", lastSeenKey: "CNTrialLastSeen")
    }

    func testDefaultsRoundTrip() throws {
        let store = defaultsStore()
        XCTAssertNil(try store.load())
        let record = TrialRecord(startDate: t0, lastSeenDate: t0.addingTimeInterval(hour))
        try store.save(record)
        XCTAssertEqual(try store.load(), record)
        store.clear()
        XCTAssertNil(try store.load())
    }

    func testDefaultsWithOnlyALastSeenCountsAsUsedUp() throws {
        let store = defaultsStore()
        store.defaults.set(t0, forKey: store.lastSeenKey)
        let record = try XCTUnwrap(store.load())
        XCTAssertEqual(TrialClock.status(of: record, now: t0), .expired)
    }

    func testEitherCopyAloneRestores() throws {
        let record = TrialRecord(startDate: t0, lastSeenDate: t0.addingTimeInterval(2 * day))
        // Keychain kept, defaults deleted.
        let keychain = MemoryTrialStore(record)
        let defaults = defaultsStore()
        let mirrored = MirroredTrialStore([keychain, defaults])
        XCTAssertEqual(try mirrored.load(), record)
        try mirrored.save(record)
        XCTAssertEqual(try defaults.load(), record, "the deleted copy is written back")

        // Defaults kept, Keychain deleted.
        let keychain2 = MemoryTrialStore()
        let defaults2 = defaultsStore()
        try defaults2.save(record)
        let mirrored2 = MirroredTrialStore([keychain2, defaults2])
        XCTAssertEqual(try mirrored2.load(), record)
        try mirrored2.save(record)
        XCTAssertEqual(keychain2.record, record)
    }

    func testDisagreeingCopiesMergeConservativelyAndBothAreFixed() throws {
        let keychain = MemoryTrialStore(TrialRecord(startDate: t0, lastSeenDate: t0.addingTimeInterval(day)))
        let defaults = MemoryTrialStore(TrialRecord(startDate: t0.addingTimeInterval(3 * day), lastSeenDate: t0.addingTimeInterval(4 * day)))
        let mirrored = MirroredTrialStore([keychain, defaults])
        let merged = try XCTUnwrap(mirrored.load())
        XCTAssertEqual(merged, TrialRecord(startDate: t0, lastSeenDate: t0.addingTimeInterval(4 * day)))
        try mirrored.save(merged)
        XCTAssertEqual(keychain.record, merged)
        XCTAssertEqual(defaults.record, merged)
    }

    func testSavingNeverMovesACopyTheWrongWay() throws {
        let stored = TrialRecord(startDate: t0, lastSeenDate: t0.addingTimeInterval(5 * day))
        let keychain = MemoryTrialStore(stored)
        let mirrored = MirroredTrialStore([keychain])
        try mirrored.save(TrialRecord(startDate: t0.addingTimeInterval(day), lastSeenDate: t0.addingTimeInterval(2 * day)))
        XCTAssertEqual(keychain.record, stored)
    }

    func testAnUnreadableCopyIsNotNoTrial() throws {
        let keychain = MemoryTrialStore(TrialRecord(startDate: t0, lastSeenDate: t0))
        keychain.failingReads = 1
        let mirrored = MirroredTrialStore([keychain, MemoryTrialStore()])
        XCTAssertThrowsError(try mirrored.load(), "nothing readable, one copy unreadable: wait, don't start over")
        // An unreadable copy is left alone by a save (it could hold an earlier start).
        keychain.failingReads = 1
        let other = MemoryTrialStore()
        try MirroredTrialStore([keychain, other]).save(TrialRecord(startDate: t0.addingTimeInterval(day), lastSeenDate: t0.addingTimeInterval(day)))
        XCTAssertEqual(keychain.record, TrialRecord(startDate: t0, lastSeenDate: t0))
        XCTAssertNotNil(other.record)
    }

    func testDebugAndRealKeysAreSeparate() throws {
        let real = MirroredTrialStore.keychainAndDefaults(account: "activation").stores.compactMap { $0 as? DefaultsTrialStore }.first
        let debug = MirroredTrialStore.keychainAndDefaults(account: "debug-activation").stores.compactMap { $0 as? DefaultsTrialStore }.first
        XCTAssertEqual(real?.startKey, "CNTrialStart")
        XCTAssertEqual(real?.lastSeenKey, "CNTrialLastSeen")
        XCTAssertEqual(debug?.startKey, "CNDebugTrialStart")
        XCTAssertEqual(debug?.lastSeenKey, "CNDebugTrialLastSeen")
        let realKeychain = MirroredTrialStore.keychainAndDefaults(account: "activation").stores.compactMap { $0 as? KeychainTrialStore }.first
        let debugKeychain = MirroredTrialStore.keychainAndDefaults(account: "debug-activation").stores.compactMap { $0 as? KeychainTrialStore }.first
        XCTAssertEqual(realKeychain?.account, "activation.trial")
        XCTAssertEqual(debugKeychain?.account, "debug-activation.trial")
        XCTAssertEqual(realKeychain?.service, "com.cinenotch.CineNotch.license")
    }
}

@MainActor
final class TrialManagerTests: XCTestCase {
    private func manager(_ store: TrialStoring, _ clock: Clock, fixed: Int? = nil) -> TrialManager {
        TrialManager(store: store, now: { clock.date }, fixedDaysLeft: fixed)
    }

    func testNothingHappensUntilStarted() {
        let store = MemoryTrialStore()
        let m = manager(store, Clock(t0))
        m.refresh()
        XCTAssertEqual(m.status, .inactive)
        XCTAssertNil(store.record)
        XCTAssertEqual(store.saves, 0)
    }

    func testFirstLaunchRecordsOnceAndCountsDown() {
        let store = MemoryTrialStore()
        let clock = Clock(t0)
        let m = manager(store, clock)
        m.start()
        XCTAssertEqual(m.status, .active(daysLeft: 7))
        XCTAssertEqual(store.record, TrialRecord(startDate: t0, lastSeenDate: t0))
        clock.date = t0.addingTimeInterval(2 * day + hour)
        m.refresh()
        XCTAssertEqual(m.status, .active(daysLeft: 5))
        XCTAssertEqual(store.record?.startDate, t0, "the start is recorded once")
        XCTAssertEqual(store.record?.lastSeenDate, clock.date)
        clock.date = t0.addingTimeInterval(7 * day)
        m.refresh()
        XCTAssertEqual(m.status, .expired)
        m.stop()

        // A later launch picks the same record up.
        clock.date = t0.addingTimeInterval(3 * day)
        let again = manager(store, clock)
        again.start()
        XCTAssertEqual(again.status, .expired, "the clock set back after expiry doesn't reopen it")
        again.stop()
    }

    func testClockSetBackAtLaunch() {
        let store = MemoryTrialStore(TrialRecord(startDate: t0, lastSeenDate: t0.addingTimeInterval(4 * day)))
        let clock = Clock(t0.addingTimeInterval(-10 * day))
        let m = manager(store, clock)
        m.start()
        XCTAssertEqual(m.status, .active(daysLeft: 3))
        XCTAssertEqual(store.record?.startDate, t0, "no new window")
        XCTAssertEqual(store.record?.lastSeenDate, t0.addingTimeInterval(4 * day), "last-seen never moves back")
        m.stop()
    }

    func testDeletingTheStoreDuringARunDoesNotRestart() {
        let store = MemoryTrialStore()
        let clock = Clock(t0)
        let m = manager(store, clock)
        m.start()
        clock.date = t0.addingTimeInterval(3 * day)
        m.refresh()
        store.clear()
        clock.date = t0.addingTimeInterval(3 * day + hour)
        m.refresh()
        XCTAssertEqual(m.status, .active(daysLeft: 4))
        XCTAssertEqual(store.record?.startDate, t0)
        m.stop()
    }

    func testUnreadableStoreDoesNotStartATrial() {
        let store = MemoryTrialStore(TrialRecord(startDate: t0.addingTimeInterval(-10 * day), lastSeenDate: t0))
        store.failingReads = 1
        let m = manager(store, Clock(t0))
        m.start()
        XCTAssertEqual(m.status, .inactive)
        XCTAssertEqual(store.saves, 0, "nothing written while unreadable")
        m.refresh()
        XCTAssertEqual(m.status, .expired)
        m.stop()
    }

    func testPinnedDaysLeftNeverTouchesTheStore() {
        let store = MemoryTrialStore()
        let m = manager(store, Clock(t0), fixed: 2)
        m.start()
        XCTAssertEqual(m.status, .active(daysLeft: 2))
        m.refresh()
        XCTAssertEqual(m.status, .active(daysLeft: 2))
        XCTAssertNil(store.record)
        XCTAssertEqual(store.saves, 0)

        let ended = manager(store, Clock(t0), fixed: 0)
        ended.start()
        XCTAssertEqual(ended.status, .expired)
        XCTAssertNil(store.record)
    }

    func testBuyURL() {
        XCTAssertEqual(TrialManager.buyURL.absoluteString, "https://cinenotch.cam/?ref=trial")
    }
}

/// The license manager's side: the trial waits for a real decision, never the placeholder shown before the Keychain is read.
@MainActor
final class TrialLicenseStateTests: XCTestCase {
    private final class NoServer: LicenseServing, @unchecked Sendable {
        var calls = 0
        func activate(key: String, deviceID: String, deviceLabel: String, instanceID: String?) async throws -> LicenseGrant {
            calls += 1
            throw LicenseServerError.unavailable
        }
        func validate(key: String, instanceID: String, deviceID: String) async throws -> LicenseGrant {
            calls += 1
            throw LicenseServerError.unavailable
        }
        func deactivate(key: String, instanceID: String, deviceID: String) async throws { calls += 1 }
    }

    private var config: LicenseConfiguration {
        LicenseConfiguration(info: ["LicensingEnabled": true, "LicensePublicKey": "21B8rmQKBmwFXoNOwRBCp0Wqv0erC7zH8e4FZWVfDsQ="])
    }

    func testStateIsKnownOnlyAfterTheKeychainIsRead() {
        let store = MemoryLicenseStore()
        store.failingReads = 1
        let server = NoServer()
        let m = LicenseManager(configuration: config, store: store, server: server, deviceID: "d", deviceLabel: "t", now: { t0 })
        XCTAssertEqual(m.state, .unlicensed(.never))
        XCTAssertFalse(m.isStateKnown, "the locked placeholder isn't a decision")
        m.start()
        XCTAssertFalse(m.isStateKnown, "unreadable Keychain: still undecided")
        m.stop()

        let fresh = LicenseManager(configuration: config, store: MemoryLicenseStore(), server: server, deviceID: "d", deviceLabel: "t", now: { t0 })
        fresh.start()
        XCTAssertTrue(fresh.isStateKnown)
        XCTAssertTrue(TrialAccess.appliesTo(fresh.state))
        fresh.stop()

        let early = LicenseManager(configuration: config, store: MemoryLicenseStore(), server: server, deviceID: "d", deviceLabel: "t",
                                   now: { t0 }, priorInstall: true)
        early.start()
        XCTAssertTrue(early.isStateKnown)
        XCTAssertFalse(TrialAccess.appliesTo(early.state))
        early.stop()

        let pinned = LicenseManager(configuration: LicenseConfiguration(), store: MemoryLicenseStore(), server: server,
                                    deviceID: "d", deviceLabel: "t", fixedState: .unlicensed(.revoked))
        XCTAssertTrue(pinned.isStateKnown)
        XCTAssertFalse(TrialAccess.isUnlocked(pinned.state, trial: .active(daysLeft: 7)))
        XCTAssertEqual(server.calls, 0, "no network")
    }
}
