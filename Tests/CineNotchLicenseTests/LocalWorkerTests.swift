import CryptoKit
import XCTest
@testable import CineNotchLicense

/// Runs the real client against a local Worker and the mock Creem (site repo: scripts/mock-creem.mjs, `wrangler dev --port 4321`).
/// Skipped unless CINENOTCH_LICENSE_TEST_SERVER (e.g. http://127.0.0.1:4321) and CINENOTCH_LICENSE_TEST_PUBLIC_KEY
/// (the public half printed by scripts/gen-license-keys.mjs --dev) are set. See docs/LICENSING.md.
@MainActor
final class LocalWorkerTests: XCTestCase {
    private var server: URL!
    private var publicKey: String!

    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["CINENOTCH_LICENSE_TEST_SERVER"].flatMap(URL.init(string:)),
              let key = env["CINENOTCH_LICENSE_TEST_PUBLIC_KEY"] else {
            throw XCTSkip("No local Worker configured")
        }
        server = url
        publicKey = key
    }

    private func manager(store: LicenseStoring, deviceID: String) -> LicenseManager {
        let configuration = LicenseConfiguration(info: ["LicensingEnabled": true, "LicensePublicKey": publicKey], serverOverride: server)
        return LicenseManager(configuration: configuration, store: store, server: HTTPLicenseServer(baseURL: server),
                              deviceID: deviceID, deviceLabel: "XCTest")
    }

    func testActivateValidateDeactivateAgainstTheWorker() async throws {
        let device = LicenseHash.sha256Hex("xctest-\(UUID().uuidString)")
        let store = MemoryLicenseStore()
        let m = manager(store: store, deviceID: device)
        m.start()
        let missing = await m.activate(key: "CN-TEST-NOPE-9999")
        XCTAssertFalse(missing)
        let revoked = await m.activate(key: "CN-TEST-REVOKED-0001")
        XCTAssertFalse(revoked)
        XCTAssertFalse(m.isUnlocked)
        let ok = await m.activate(key: "CN-TEST-ACTIVE-0002")
        XCTAssertTrue(ok, m.message ?? "")
        XCTAssertTrue(m.isUnlocked)
        await m.revalidateIfDue(force: true)
        XCTAssertEqual(m.message, "Your license is valid.")
        let freed = await m.deactivate()
        XCTAssertTrue(freed, m.message ?? "")
        XCTAssertFalse(m.isUnlocked)
        m.stop()
    }

    func testFourthMacIsRefused() async throws {
        var managers: [LicenseManager] = []
        for i in 0..<4 {
            let m = manager(store: MemoryLicenseStore(), deviceID: LicenseHash.sha256Hex("xctest-limit-\(UUID().uuidString)-\(i)"))
            m.start()
            let ok = await m.activate(key: "CN-TEST-ACTIVE-0001")
            XCTAssertEqual(ok, i < 3, "Mac \(i + 1): \(m.message ?? "")")
            managers.append(m)
        }
        for m in managers { _ = await m.deactivate() }
    }

    func testUnreachableServerIsNotAVerdict() async {
        let configuration = LicenseConfiguration(info: ["LicensingEnabled": true, "LicensePublicKey": publicKey])
        let dead = HTTPLicenseServer(baseURL: URL(string: "http://127.0.0.1:1")!)
        do {
            _ = try await dead.validate(key: "CN-TEST-ACTIVE-0001", instanceID: "x", deviceID: String(repeating: "a", count: 64))
            XCTFail()
        } catch {
            XCTAssertEqual(error as? LicenseServerError, .unavailable)
        }
        _ = configuration
    }
}
