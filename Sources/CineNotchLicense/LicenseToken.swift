import CryptoKit
import Foundation

/// What a signed activation token says. The licensing proxy on cinenotch.cam (src/license.js in the site repo)
/// writes it; the app only reads it, offline, with the public key it ships with.
public struct LicenseClaims: Codable, Equatable, Sendable {
    public var v: Int
    /// SHA-256 (hex) of the license key.
    public var kh: String
    /// The device id hash of the Mac it was activated on.
    public var dh: String
    /// Creem's instance id for this activation.
    public var iid: String
    /// Creem's product id.
    public var pid: String
    /// Issued at and expires at, seconds since 1970.
    public var iat: Int
    public var exp: Int

    public var issuedAt: Date { Date(timeIntervalSince1970: TimeInterval(iat)) }
    public var expiresAt: Date { Date(timeIntervalSince1970: TimeInterval(exp)) }
}

public enum LicenseTokenError: Error, Equatable {
    case malformed
    case unsupportedVersion
    case badSignature
}

/// `cn1.<base64url payload JSON>.<base64url Ed25519 signature>`, signed over `domain + payload`.
/// This is a light, honest-user check: the source is public, so it keeps honest people honest and nothing more.
public enum LicenseToken {
    static let domain = Data("CINENOTCH-LICENSE-V1\n".utf8)

    public static func verify(_ token: String, publicKey: Curve25519.Signing.PublicKey) throws -> LicenseClaims {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "cn1",
              let payload = Data(base64URL: String(parts[1])),
              let signature = Data(base64URL: String(parts[2])) else { throw LicenseTokenError.malformed }
        guard publicKey.isValidSignature(signature, for: domain + payload) else { throw LicenseTokenError.badSignature }
        guard let claims = try? JSONDecoder().decode(LicenseClaims.self, from: payload) else { throw LicenseTokenError.malformed }
        guard claims.v == 1 else { throw LicenseTokenError.unsupportedVersion }
        return claims
    }

    /// For tests and the mock: signs claims the way the Worker does.
    public static func sign(_ claims: LicenseClaims, with key: Curve25519.Signing.PrivateKey) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(claims)
        let signature = try key.signature(for: domain + payload)
        return "cn1.\(payload.base64URL).\(signature.base64URL)"
    }
}

extension Data {
    init?(base64URL text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }

    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum LicenseHash {
    public static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
