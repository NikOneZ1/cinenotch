import CryptoKit
import XCTest
@testable import CineNotchLicense

/// A token the real Worker code (src/license.js in the site repo) produced from a throwaway key.
/// If this fails after a change to either side, the app and the Worker no longer agree on the token format.
private enum Vector {
    static let publicKey = "21B8rmQKBmwFXoNOwRBCp0Wqv0erC7zH8e4FZWVfDsQ="
    static let token = "cn1.eyJ2IjoxLCJraCI6ImUxZTEyYzVjZWNlZmIwMjYzNDU3NzQ5NTdmM2U5ODdkNjFhODQyZGU2YWM5ZGU2ZjVmMmU0ZTAxZjIxOWVmNmIiLCJkaCI6IjExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTExMTEiLCJpaWQiOiJpbnN0X3ZlYyIsInBpZCI6InByb2RfdmVjIiwiaWF0IjoxNzkzNTM0NDAwLCJleHAiOjE4NTY2MDY0MDB9.Msp1t8sEnmww9JhCzPHTzJzCs4L6q-7h3QoUxPVlP7bYHzDOcABCBUifkys0sR42B57iCDv9Pj5NKc3P8DWXAw"
    static let key = "VECTOR-KEY-0001-ABCD"
    static let device = String(repeating: "1", count: 64)
    /// 2026-11-01T12:00:00Z
    static let issued = Date(timeIntervalSince1970: 1_793_534_400)
}

private final class FakeServer: LicenseServing, @unchecked Sendable {
    var result: Result<LicenseGrant, LicenseServerError>
    var deactivateResult: LicenseServerError?
    var calls: [String] = []
    var heldInstance: String??
    init(_ result: Result<LicenseGrant, LicenseServerError>) { self.result = result }
    func activate(key: String, deviceID: String, deviceLabel: String, instanceID: String?) async throws -> LicenseGrant {
        calls.append("activate")
        heldInstance = instanceID
        return try result.get()
    }
    func validate(key: String, instanceID: String, deviceID: String) async throws -> LicenseGrant { calls.append("validate"); return try result.get() }
    func deactivate(key: String, instanceID: String, deviceID: String) async throws {
        calls.append("deactivate")
        if let deactivateResult { throw deactivateResult }
    }
}

/// Validates slowly, so an activation can be tried meanwhile.
private final class SlowServer: LicenseServing, @unchecked Sendable {
    let grant: LicenseGrant
    var calls: [String] = []
    init(_ grant: LicenseGrant) { self.grant = grant }
    func activate(key: String, deviceID: String, deviceLabel: String, instanceID: String?) async throws -> LicenseGrant { calls.append("activate"); return grant }
    func validate(key: String, instanceID: String, deviceID: String) async throws -> LicenseGrant {
        calls.append("validate")
        try await Task.sleep(nanoseconds: 300_000_000)
        return grant
    }
    func deactivate(key: String, instanceID: String, deviceID: String) async throws {}
}

final class LicenseTokenTests: XCTestCase {
    private var publicKey: Curve25519.Signing.PublicKey {
        try! Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: Vector.publicKey)!)
    }

    func testVerifiesTokenFromTheWorker() throws {
        let claims = try LicenseToken.verify(Vector.token, publicKey: publicKey)
        XCTAssertEqual(claims.v, 1)
        XCTAssertEqual(claims.iid, "inst_vec")
        XCTAssertEqual(claims.pid, "prod_vec")
        XCTAssertEqual(claims.dh, Vector.device)
        XCTAssertEqual(claims.kh, LicenseHash.sha256Hex(Vector.key))
        XCTAssertEqual(claims.issuedAt, Vector.issued)
        XCTAssertEqual(claims.exp - claims.iat, 730 * 86400)
    }

    func testRejectsTamperingAndOtherKeys() {
        var parts = Vector.token.split(separator: ".").map(String.init)
        var payload = Data(base64URL: parts[1])!
        payload[10] ^= 1
        parts[1] = payload.base64URL
        XCTAssertThrowsError(try LicenseToken.verify(parts.joined(separator: "."), publicKey: publicKey)) {
            XCTAssertEqual($0 as? LicenseTokenError, .badSignature)
        }
        let other = Curve25519.Signing.PrivateKey().publicKey
        XCTAssertThrowsError(try LicenseToken.verify(Vector.token, publicKey: other))
        XCTAssertThrowsError(try LicenseToken.verify("nonsense", publicKey: publicKey))
        XCTAssertThrowsError(try LicenseToken.verify("cn1.a.b", publicKey: publicKey))
    }

    func testSignAndVerifyRoundTrip() throws {
        let key = Curve25519.Signing.PrivateKey()
        let claims = LicenseClaims(v: 1, kh: "a", dh: "b", iid: "c", pid: "d", iat: 1, exp: 2)
        let token = try LicenseToken.sign(claims, with: key)
        XCTAssertEqual(try LicenseToken.verify(token, publicKey: key.publicKey), claims)
    }
}

final class LicenseConfigurationTests: XCTestCase {
    func testOffByDefault() {
        XCTAssertEqual(LicenseConfiguration(info: nil).mode, .off)
        XCTAssertEqual(LicenseConfiguration(info: ["LicensePublicKey": Vector.publicKey]).mode, .off)
        XCTAssertFalse(LicenseConfiguration(info: ["LicensingEnabled": false, "LicensePublicKey": Vector.publicKey]).isEnforced)
    }

    func testOnNeedsAValidKey() {
        XCTAssertEqual(LicenseConfiguration(info: ["LicensingEnabled": true, "LicensePublicKey": Vector.publicKey]).mode, .on)
        guard case .misconfigured = LicenseConfiguration(info: ["LicensingEnabled": true]).mode else { return XCTFail() }
        guard case .misconfigured = LicenseConfiguration(info: ["LicensingEnabled": true, "LicensePublicKey": "abc"]).mode else { return XCTFail() }
        XCTAssertFalse(LicenseConfiguration(info: ["LicensingEnabled": true]).isEnforced, "a missing key must fail open")
    }
}

@MainActor
final class LicenseManagerTests: XCTestCase {
    private var config: LicenseConfiguration {
        LicenseConfiguration(info: ["LicensingEnabled": true, "LicensePublicKey": Vector.publicKey])
    }
    private var grant: LicenseGrant { LicenseGrant(token: Vector.token, instanceID: "inst_vec", activation: 1, activationLimit: 3) }

    private func manager(_ store: LicenseStoring, _ server: LicenseServing, now: Date = Vector.issued.addingTimeInterval(60),
                         configuration: LicenseConfiguration? = nil, clock: ClockBox? = nil, priorInstall: Bool = false) -> LicenseManager {
        LicenseManager(configuration: configuration ?? config, store: store, server: server, deviceID: Vector.device,
                       deviceLabel: "Test", now: { clock?.date ?? now }, priorInstall: priorInstall)
    }

    final class ClockBox { var date: Date; init(_ d: Date) { date = d } }

    private func stored(validated: Date = Vector.issued) -> StoredLicense {
        StoredLicense(key: Vector.key, instanceID: "inst_vec", token: Vector.token, activatedAt: Vector.issued, lastValidatedAt: validated)
    }

    func testOffMeansUnlockedAndNothingHappens() async {
        let server = FakeServer(.failure(.unavailable))
        let m = manager(MemoryLicenseStore(), server, configuration: LicenseConfiguration(info: nil))
        m.start()
        XCTAssertEqual(m.state, .off)
        XCTAssertTrue(m.isUnlocked)
        XCTAssertFalse(m.isEnforced)
        await m.revalidateIfDue(force: true)
        XCTAssertEqual(server.calls, [])
    }

    func testStartsLockedThenLicensedFromStore() {
        let m = manager(MemoryLicenseStore(stored()), FakeServer(.failure(.unavailable)))
        XCTAssertFalse(m.isUnlocked)
        m.start()
        guard case .licensed(let s) = m.state else { return XCTFail("\(m.state)") }
        XCTAssertEqual(s.keyHint, "…ABCD")
        XCTAssertFalse(s.needsReconnect)
        XCTAssertTrue(m.isUnlocked)
        m.stop()
    }

    func testActivateStoresAndUnlocks() async {
        let store = MemoryLicenseStore()
        let m = manager(store, FakeServer(.success(grant)))
        m.start()
        XCTAssertEqual(m.state, .unlicensed(.never))
        let ok = await m.activate(key: "  \(Vector.key)\n")
        XCTAssertTrue(ok)
        XCTAssertTrue(m.isUnlocked)
        XCTAssertEqual(try? store.load()?.key, Vector.key)
        m.stop()
    }

    func testActivatingTheSameKeyAgainOffersTheHeldInstance() async {
        // Creem makes a new instance on every activation: the Worker reuses the held one instead of taking a slot.
        var license = stored()
        license.revokedAt = Vector.issued
        let server = FakeServer(.success(grant))
        let m = manager(MemoryLicenseStore(license), server)
        m.start()
        await m.activate(key: Vector.key)
        XCTAssertEqual(server.heldInstance, .some("inst_vec"))
        await m.activate(key: "ANOTHER-KEY-0002")
        XCTAssertEqual(server.heldInstance, .some(nil), "another key has nothing to reuse")
        m.stop()
    }

    func testActivateRefusalsStayLockedAndExplain() async {
        for error in [LicenseServerError.notFound, .limitReached, .revoked, .unavailable, .notEnabled] {
            let store = MemoryLicenseStore()
            let m = manager(store, FakeServer(.failure(error)))
            m.start()
            let ok = await m.activate(key: Vector.key)
            XCTAssertFalse(ok)
            XCTAssertFalse(m.isUnlocked)
            XCTAssertNil(try? store.load())
            XCTAssertNotNil(m.message)
        }
    }

    func testTokenForAnotherKeyOrMacIsRefused() async {
        let m = manager(MemoryLicenseStore(), FakeServer(.success(grant)))
        m.start()
        let wrongKey = await m.activate(key: "SOME-OTHER-KEY")
        XCTAssertFalse(wrongKey)
        let otherMac = LicenseManager(configuration: config, store: MemoryLicenseStore(), server: FakeServer(.success(grant)),
                                      deviceID: String(repeating: "2", count: 64), deviceLabel: "x", now: { Vector.issued })
        otherMac.start()
        let wrongMac = await otherMac.activate(key: Vector.key)
        XCTAssertFalse(wrongMac)
    }

    func testStoredLicenseFromAnotherMacIsInvalid() {
        let m = LicenseManager(configuration: config, store: MemoryLicenseStore(stored()), server: FakeServer(.failure(.unavailable)),
                               deviceID: String(repeating: "2", count: 64), deviceLabel: "x", now: { Vector.issued })
        m.start()
        XCTAssertEqual(m.state, .unlicensed(.storedInvalid))
    }

    func testOfflineNeverLocksButReminds() async {
        let clock = ClockBox(Vector.issued.addingTimeInterval(20 * 86400))
        let server = FakeServer(.failure(.unavailable))
        let m = manager(MemoryLicenseStore(stored()), server, clock: clock)
        m.start()
        await m.revalidateIfDue()
        XCTAssertTrue(m.isUnlocked, "a failed check must not lock")
        XCTAssertEqual(server.calls, ["validate"])
        await m.revalidateIfDue()
        XCTAssertEqual(server.calls, ["validate"], "after a failure it waits a few hours before trying again")
        clock.date = Vector.issued.addingTimeInterval(60 * 86400)
        m.start()
        guard case .licensed(let s) = m.state else { return XCTFail() }
        XCTAssertTrue(s.needsReconnect)
        XCTAssertTrue(m.isUnlocked)
        m.stop()
    }

    func testNoCheckBeforeFourteenDays() async {
        let server = FakeServer(.success(grant))
        let m = manager(MemoryLicenseStore(stored()), server, now: Vector.issued.addingTimeInterval(13 * 86400))
        m.start()
        await m.revalidateIfDue()
        XCTAssertEqual(server.calls, [])
        m.stop()
    }

    func testSuccessfulRevalidationRefreshesTheClock() async {
        let store = MemoryLicenseStore(stored())
        let clock = ClockBox(Vector.issued.addingTimeInterval(15 * 86400))
        let m = manager(store, FakeServer(.success(grant)), clock: clock)
        m.start()
        await m.revalidateIfDue()
        XCTAssertEqual(try? store.load()?.lastValidatedAt, clock.date)
        m.stop()
    }

    func testOneRefusalDoesntLockARepeatedOneDoesAndKeepsTheKey() async {
        let store = MemoryLicenseStore(stored())
        let server = FakeServer(.failure(.revoked))
        let clock = ClockBox(Vector.issued.addingTimeInterval(15 * 86400))
        let m = manager(store, server, clock: clock)
        m.start()
        await m.revalidateIfDue()
        XCTAssertTrue(m.isUnlocked, "a single 'not valid' only waits for confirmation")
        XCTAssertNotNil(try? store.load()?.refusedAt)
        await m.revalidateIfDue(force: true)
        XCTAssertTrue(m.isUnlocked, "a repeat within the hour isn't a confirmation")
        clock.date = clock.date.addingTimeInterval(7 * 3600)
        await m.revalidateIfDue()
        XCTAssertEqual(m.state, .unlicensed(.revoked))
        XCTAssertEqual(try? store.load()?.key, Vector.key, "the key is kept")
        XCTAssertTrue(m.canRecheck)
        m.start()
        XCTAssertEqual(m.state, .unlicensed(.revoked), "and it stays locked after a relaunch")
        m.stop()
    }

    func testARefusalFollowedBySuccessIsForgotten() async {
        let store = MemoryLicenseStore(stored())
        let server = FakeServer(.failure(.notFound))
        let clock = ClockBox(Vector.issued.addingTimeInterval(15 * 86400))
        let m = manager(store, server, clock: clock)
        m.start()
        await m.revalidateIfDue()
        server.result = .success(grant)
        clock.date = clock.date.addingTimeInterval(7 * 3600)
        await m.revalidateIfDue()
        XCTAssertTrue(m.isUnlocked)
        XCTAssertNil(try? store.load()?.refusedAt)
        server.result = .failure(.notFound)
        clock.date = clock.date.addingTimeInterval(20 * 86400)
        await m.revalidateIfDue()
        XCTAssertTrue(m.isUnlocked, "a new run of refusals starts from one")
        m.stop()
    }

    func testALockedMacUnlocksByItselfWhenTheServerChangesItsMind() async {
        // What a misconfigured server would do to every Mac, and how they recover once it's fixed.
        var license = stored()
        license.revokedAt = Vector.issued.addingTimeInterval(14 * 86400)
        let store = MemoryLicenseStore(license)
        let server = FakeServer(.failure(.revoked))
        let clock = ClockBox(Vector.issued.addingTimeInterval(15 * 86400))
        let m = manager(store, server, clock: clock)
        m.start()
        await m.revalidateIfDue()
        XCTAssertEqual(server.calls, ["validate"], "a locked Mac with a key checks at launch")
        XCTAssertFalse(m.isUnlocked)
        await m.revalidateIfDue()
        XCTAssertEqual(server.calls.count, 1, "then once a day")
        server.result = .success(grant)
        clock.date = clock.date.addingTimeInterval(86400 + 60)
        await m.revalidateIfDue()
        XCTAssertTrue(m.isUnlocked)
        XCTAssertNil(try? store.load()?.revokedAt)
        XCTAssertEqual(m.message, "Your license is valid again.")
        m.stop()
    }

    func testAnUnreadableKeychainIsNotAnUnpaidMac() async {
        let store = MemoryLicenseStore(stored())
        store.failingReads = 1
        let server = FakeServer(.success(grant))
        let m = manager(store, server)
        m.start()
        XCTAssertEqual(m.state, .unlicensed(.never), "nothing decided yet")
        XCTAssertNil(try? store.loadEarlyAccess(), "and nothing written")
        let ok = await m.activate(key: Vector.key)
        XCTAssertFalse(ok, "no activation over a license that couldn't be read")
        XCTAssertEqual(server.calls, [])
        m.start()
        guard case .licensed = m.state else { return XCTFail("\(m.state)") }
        m.stop()
    }

    func testActivateWaitsForABackgroundCheck() async {
        let server = SlowServer(grant)
        let clock = ClockBox(Vector.issued.addingTimeInterval(15 * 86400))
        let m = manager(MemoryLicenseStore(stored()), server, clock: clock)
        m.start()
        let check = Task { await m.revalidateIfDue(force: true) }
        await Task.yield()
        let ok = await m.activate(key: Vector.key)
        await check.value
        XCTAssertTrue(ok, "the click isn't lost while a check is running")
        XCTAssertEqual(server.calls, ["validate", "activate"])
        m.stop()
    }

    // MARK: Early supporters

    func testAMacThatUsedCineNotchBeforeIsFreeForGood() async {
        let store = MemoryLicenseStore()
        let server = FakeServer(.failure(.revoked))
        let m = manager(store, server, priorInstall: true)
        XCTAssertFalse(m.isUnlocked)
        m.start()
        guard case .earlySupporter = m.state else { return XCTFail("\(m.state)") }
        XCTAssertTrue(m.isUnlocked)
        await m.revalidateIfDue(force: true)
        XCTAssertEqual(server.calls, [], "nothing is ever checked")
        XCTAssertEqual(try? store.loadEarlyAccess()?.isEarlySupporter, true)
        let later = manager(store, server, priorInstall: false)
        later.start()
        guard case .earlySupporter = later.state else { return XCTFail("the decision is kept: \(later.state)") }
        m.stop()
        later.stop()
    }

    func testANewMacStaysNewEvenAfterItHasSettings() {
        let store = MemoryLicenseStore()
        let first = manager(store, FakeServer(.failure(.unavailable)), priorInstall: false)
        first.start()
        XCTAssertEqual(first.state, .unlicensed(.never))
        XCTAssertEqual(try? store.loadEarlyAccess()?.isEarlySupporter, false)
        // Next launch: onboarding has run, so the "used before" evidence is there now. The saved decision wins.
        let next = manager(store, FakeServer(.failure(.unavailable)), priorInstall: true)
        next.start()
        XCTAssertEqual(next.state, .unlicensed(.never))
        first.stop()
        next.stop()
    }

    func testEarlySupporterNeedsNothingWhenLicensingIsOff() {
        let store = MemoryLicenseStore()
        let m = manager(store, FakeServer(.failure(.unavailable)), configuration: LicenseConfiguration(info: nil), priorInstall: true)
        m.start()
        XCTAssertEqual(m.state, .off)
        XCTAssertNil(try? store.loadEarlyAccess(), "with licensing off nothing is written")
    }

    func testDeactivateFreesTheSlot() async {
        let store = MemoryLicenseStore(stored())
        let server = FakeServer(.success(grant))
        let m = manager(store, server)
        m.start()
        let ok = await m.deactivate()
        XCTAssertTrue(ok)
        XCTAssertEqual(server.calls, ["deactivate"])
        XCTAssertNil(try? store.load())
        XCTAssertEqual(m.state, .unlicensed(.never))
        m.stop()
    }

    func testDeactivateOfflineKeepsTheLicense() async {
        let store = MemoryLicenseStore(stored())
        let server = FakeServer(.success(grant))
        server.deactivateResult = .unavailable
        let m = manager(store, server)
        m.start()
        let ok = await m.deactivate()
        XCTAssertFalse(ok)
        XCTAssertNotNil(try? store.load())
        XCTAssertTrue(m.isUnlocked)
        m.forgetLocally()
        XCTAssertNil(try? store.load())
        m.stop()
    }

    func testFixedDebugStateTouchesNothing() async {
        let server = FakeServer(.success(grant))
        let store = MemoryLicenseStore()
        let m = LicenseManager(configuration: config, store: store, server: server, deviceID: Vector.device, deviceLabel: "x",
                               fixedState: .unlicensed(.never))
        m.start()
        XCTAssertFalse(m.isUnlocked)
        XCTAssertTrue(m.isEnforced)
        let ok = await m.activate(key: Vector.key)
        XCTAssertFalse(ok)
        XCTAssertEqual(server.calls, [])
        XCTAssertNil(try? store.load())
    }
}

final class LicenseServerErrorTests: XCTestCase {
    func testWorkerErrorCodesMap() {
        XCTAssertEqual(HTTPLicenseServer.error(for: "licensing_not_enabled"), .notEnabled)
        XCTAssertEqual(HTTPLicenseServer.error(for: "not_found"), .notFound)
        XCTAssertEqual(HTTPLicenseServer.error(for: "limit_reached"), .limitReached)
        XCTAssertEqual(HTTPLicenseServer.error(for: "something_new"), .unavailable)
        XCTAssertTrue(LicenseServerError.revoked.isFinal)
        XCTAssertFalse(LicenseServerError.unavailable.isFinal)
        XCTAssertFalse(LicenseServerError.notEnabled.isFinal)
    }
}
