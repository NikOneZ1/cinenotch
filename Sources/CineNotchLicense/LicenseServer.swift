import Foundation

/// What the licensing proxy gave back for an activation or a validation.
public struct LicenseGrant: Equatable, Sendable {
    public var token: String
    public var instanceID: String
    public var activation: Int?
    public var activationLimit: Int?
}

/// Why the server said no. `isFinal` ones mean "this license is not valid for this Mac": the app locks.
/// Everything else (no network, server trouble, licensing switched off on the server) is "try later": the app keeps working.
public enum LicenseServerError: Error, Equatable {
    case notEnabled
    case notFound
    case revoked
    case limitReached
    case rateLimited
    case invalidRequest
    case unavailable

    public var isFinal: Bool { self == .notFound || self == .revoked }
}

public protocol LicenseServing: Sendable {
    func activate(key: String, deviceID: String, deviceLabel: String) async throws -> LicenseGrant
    func validate(key: String, instanceID: String, deviceID: String) async throws -> LicenseGrant
    func deactivate(key: String, instanceID: String, deviceID: String) async throws
}

/// Talks to https://cinenotch.cam/api/license/* (see the site repo, src/license.js). Only these three calls leave the app:
/// the license key, the hashed device id, the instance id and the hardware model. Never video, camera or screen data.
public struct HTTPLicenseServer: LicenseServing {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL, session: URLSession = HTTPLicenseServer.defaultSession) {
        self.baseURL = baseURL
        self.session = session
    }

    public static let defaultSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        return URLSession(configuration: config)
    }()

    public func activate(key: String, deviceID: String, deviceLabel: String) async throws -> LicenseGrant {
        try grant(await post("activate", ["key": key, "device_id": deviceID, "device_label": deviceLabel]))
    }

    public func validate(key: String, instanceID: String, deviceID: String) async throws -> LicenseGrant {
        try grant(await post("validate", ["key": key, "instance_id": instanceID, "device_id": deviceID]))
    }

    public func deactivate(key: String, instanceID: String, deviceID: String) async throws {
        _ = try await post("deactivate", ["key": key, "instance_id": instanceID, "device_id": deviceID])
    }

    private struct Answer: Decodable {
        var ok: Bool?
        var error: String?
        var token: String?
        var instance_id: String?
        var license: Info?
        struct Info: Decodable {
            var activation: Int?
            var activation_limit: Int?
        }
    }

    private func post(_ action: String, _ body: [String: String]) async throws -> Answer {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/license/\(action)"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LicenseServerError.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw LicenseServerError.unavailable }
        // Only a JSON answer from the proxy counts. A 404 page from the web server, a captive portal or a proxy
        // error says nothing about the license.
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data), answer.ok != nil else {
            throw LicenseServerError.unavailable
        }
        if answer.ok == true, http.statusCode == 200 { return answer }
        throw Self.error(for: answer.error)
    }

    static func error(for code: String?) -> LicenseServerError {
        switch code {
        case "licensing_not_enabled", "not_configured": return .notEnabled
        case "not_found": return .notFound
        case "revoked": return .revoked
        case "limit_reached": return .limitReached
        case "rate_limited": return .rateLimited
        case "invalid_request": return .invalidRequest
        default: return .unavailable
        }
    }

    private func grant(_ answer: Answer) throws -> LicenseGrant {
        guard let token = answer.token, let instance = answer.instance_id ?? Self.instance(in: token) else {
            throw LicenseServerError.unavailable
        }
        return LicenseGrant(token: token, instanceID: instance, activation: answer.license?.activation,
                            activationLimit: answer.license?.activation_limit)
    }

    /// `validate` answers don't repeat the instance id, but the token has it (unverified here: the manager verifies).
    private static func instance(in token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3, let payload = Data(base64URL: String(parts[1])),
              let claims = try? JSONDecoder().decode(LicenseClaims.self, from: payload) else { return nil }
        return claims.iid
    }
}
