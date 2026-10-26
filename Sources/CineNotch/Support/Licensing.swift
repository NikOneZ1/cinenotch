import AppKit
import CineNotchLicense
import Foundation

/// Sets licensing up from Info.plist (`LicensingEnabled`, see docs/LICENSING.md) and the `--debug-license-*` options.
/// With `LicensingEnabled` false (every build until the paid version ships) the manager is inert:
/// the app is unrestricted, nothing is read from the Keychain and nothing is sent anywhere.
enum Licensing {
    @MainActor static func makeManager(options: LaunchOptions) -> LicenseManager {
        LicenseLog.sink = { Log.info($0) }
        let info = Bundle.main.infoDictionary
        var configuration = LicenseConfiguration(info: info,
                                                 enabledOverride: options.debugLicenseEnabled ? true : nil,
                                                 serverOverride: options.debugLicenseServer,
                                                 publicKeyOverride: options.debugLicensePublicKey)
        let isDebug = options.debugLicenseEnabled || options.debugLicenseServer != nil || options.debugLicensePublicKey != nil
        if isDebug { configuration.storeAccount = "debug-activation" }
        if case .misconfigured(let reason) = configuration.mode {
            Log.info("license: LicensingEnabled is on but \(reason), so the app stays unrestricted")
        }
        let fixed = options.debugLicenseState.flatMap(fixedState)
        if options.debugLicenseState != nil, fixed == nil {
            Log.info("license: unknown --debug-license-state '\(options.debugLicenseState ?? "")'")
        }
        let manager = LicenseManager(configuration: configuration,
                                     store: KeychainLicenseStore(account: configuration.storeAccount),
                                     server: HTTPLicenseServer(baseURL: configuration.serverURL),
                                     fixedState: fixed)
        Log.info("license: \(manager.isEnforced ? "on" : "off")\(isDebug ? " (debug)" : "")")
        return manager
    }

    private static func fixedState(_ name: String) -> LicenseState? {
        let day: TimeInterval = 86400
        let summary = { (stale: Bool) in
            LicenseSummary(keyHint: "…ABCD", activatedAt: Date().addingTimeInterval(-30 * day),
                           lastValidatedAt: Date().addingTimeInterval(-(stale ? 60 : 3) * day), needsReconnect: stale)
        }
        switch name {
        case "off": return .off
        case "unlicensed", "locked": return .unlicensed(.never)
        case "revoked": return .unlicensed(.revoked)
        case "licensed": return .licensed(summary(false))
        case "stale": return .licensed(summary(true))
        default: return nil
        }
    }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}
