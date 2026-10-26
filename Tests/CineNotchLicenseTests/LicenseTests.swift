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
    init(_ result: Result<LicenseGrant, LicenseServerError>) { self.result = result }
    func activate(key: String, deviceID: String, deviceLabel: String) async throws -> LicenseGrant { calls.append("activate"); return try result.get() }
    func validate(key: String, instanceID: String, deviceID: String) async throws -> LicenseGrant { calls.append("validate"); return try result.get() }
    func deactivate(key: String, instanceID: String, deviceID: String) async throws {
        calls.append("deactivate")
        if let deactivateResult { throw deactivateResult }
    }
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
                         configuration: LicenseConfiguration? = nil, clock: ClockBox? = nil) -> LicenseManager {
        LicenseManager(configuration: configuration ?? config, store: store, server: server, deviceID: Vector.device,
                       deviceLabel: "Test", now: { clock?.date ?? now })
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
        XCTAssertEqual(store.load()?.key, Vector.key)
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
            XCTAssertNil(store.load())
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
        XCTAssertEqual(store.load()?.lastValidatedAt, clock.date)
        m.stop()
    }

    func testOnlyAFinalAnswerLocks() async {
        let store = MemoryLicenseStore(stored())
        let clock = ClockBox(Vector.issued.addingTimeInterval(15 * 86400))
        let m = manager(store, FakeServer(.failure(.revoked)), clock: clock)
        m.start()
        await m.revalidateIfDue()
        XCTAssertEqual(m.state, .unlicensed(.revoked))
        XCTAssertNil(store.load())
        m.stop()
    }

    func testDeactivateFreesTheSlot() async {
        let store = MemoryLicenseStore(stored())
        let server = FakeServer(.success(grant))
        let m = manager(store, server)
        m.start()
        let ok = await m.deactivate()
        XCTAssertTrue(ok)
        XCTAssertEqual(server.calls, ["deactivate"])
        XCTAssertNil(store.load())
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
        XCTAssertNotNil(store.load())
        XCTAssertTrue(m.isUnlocked)
        m.forgetLocally()
        XCTAssertNil(store.load())
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
        XCTAssertNil(store.load())
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
