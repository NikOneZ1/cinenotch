import CryptoKit
import Foundation

/// Everything licensing needs to know, read from Info.plist (one place to switch it on):
///
///     LicensingEnabled     Boolean, false until the paid version ships. With false, nothing here runs.
///     LicensePublicKey     base64 of the 32-byte Ed25519 public key (scripts: gen-license-keys.mjs in the site repo)
///     LicenseServerURL     https://cinenotch.cam
///     LicenseBuyURL        where "Buy" goes
///     LicenseManageURL     where "Manage" goes (Creem's customer portal)
///     LicenseSupportEmail  shown when something needs a human
public struct LicenseConfiguration {
    public enum Mode: Equatable {
        /// The app is unrestricted. This is what every build is until the flag is switched on.
        case off
        case on
        /// Switched on, but the public key is missing or not a key. Fails open (the app stays unrestricted) and says why.
        case misconfigured(String)
    }

    public var mode: Mode
    public var publicKey: Curve25519.Signing.PublicKey?
    public var serverURL: URL
    public var buyURL: URL
    public var manageURL: URL
    public var supportEmail: String
    /// Keychain account: debug runs use their own, so they never touch a real activation.
    public var storeAccount = "activation"

    public static let defaultServer = URL(string: "https://cinenotch.cam")!

    public init(mode: Mode = .off, publicKey: Curve25519.Signing.PublicKey? = nil, serverURL: URL = LicenseConfiguration.defaultServer,
                buyURL: URL = URL(string: "https://cinenotch.cam/buy")!,
                manageURL: URL = URL(string: "https://www.creem.io/my-orders/login")!,
                supportEmail: String = "hello@cinenotch.cam") {
        self.mode = mode
        self.publicKey = publicKey
        self.serverURL = serverURL
        self.buyURL = buyURL
        self.manageURL = manageURL
        self.supportEmail = supportEmail
    }

    public var isEnforced: Bool { mode == .on }

    /// From the app's Info.plist.
    public init(info: [String: Any]?, enabledOverride: Bool? = nil, serverOverride: URL? = nil, publicKeyOverride: String? = nil) {
        let info = info ?? [:]
        let enabled = enabledOverride ?? (info["LicensingEnabled"] as? Bool ?? false)
        let keyText = (publicKeyOverride ?? info["LicensePublicKey"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        func url(_ key: String, _ fallback: String) -> URL { (info[key] as? String).flatMap(URL.init(string:)) ?? URL(string: fallback)! }
        self.init(serverURL: serverOverride ?? url("LicenseServerURL", "https://cinenotch.cam"),
                  buyURL: url("LicenseBuyURL", "https://cinenotch.cam/buy"),
                  manageURL: url("LicenseManageURL", "https://www.creem.io/my-orders/login"),
                  supportEmail: info["LicenseSupportEmail"] as? String ?? "hello@cinenotch.cam")
        guard enabled else { return }
        if let raw = Data(base64Encoded: keyText), raw.count == 32, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) {
            publicKey = key
            mode = .on
        } else {
            mode = .misconfigured(keyText.isEmpty ? "LicensePublicKey is empty" : "LicensePublicKey isn't a base64 Ed25519 public key")
        }
    }
}
