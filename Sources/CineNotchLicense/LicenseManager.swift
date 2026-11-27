import CryptoKit
import Foundation

/// Where the license stands.
public enum LicenseState: Equatable {
    /// Licensing is off: nothing is locked, nothing is checked, nothing is sent.
    case off
    /// Licensing is on and this Mac has no valid activation.
    case unlicensed(UnlicensedReason)
    case licensed(LicenseSummary)
    /// Used CineNotch before it was paid: free for good, nothing to activate, nothing checked.
    case earlySupporter(since: Date)
}

extension LicenseState {
    /// Whether the app's core features are available in this state.
    public var isUnlocked: Bool {
        if case .unlicensed = self { return false }
        return true
    }

    var isLicensed: Bool {
        if case .licensed = self { return true }
        return false
    }
}

public enum UnlicensedReason: Equatable {
    /// Never activated.
    case never
    /// The server said the license is no longer valid (refunded, disabled, expired, or this Mac was deactivated), twice.
    /// The key stays: the app keeps asking about once a day, and unlocks if the answer changes.
    case revoked
    /// What was stored didn't check out (another Mac's, or damaged). The key stays so one tap re-activates.
    case storedInvalid
}

public struct LicenseSummary: Equatable {
    /// "…ABCD"
    public var keyHint: String
    public var activatedAt: Date
    public var lastValidatedAt: Date
    /// Offline for a long while, or the token ran out: a gentle reminder, never a lock.
    public var needsReconnect: Bool

    public init(keyHint: String, activatedAt: Date, lastValidatedAt: Date, needsReconnect: Bool) {
        self.keyHint = keyHint
        self.activatedAt = activatedAt
        self.lastValidatedAt = lastValidatedAt
        self.needsReconnect = needsReconnect
    }
}

/// The license state machine: activation, the offline check, the soft re-validation, deactivation.
///
/// Rules, on purpose light:
/// - Once activated, the app works offline. A token that verifies against the public key and matches this Mac is enough.
/// - About every 14 days it asks the server again. If that fails because of the network or the server, nothing happens
///   (it tries again a few hours later). Only the server saying "not valid" locks the app.
/// - After 45 days without a successful check it shows a reminder to go online. Still no lock.
/// - "Not valid" locks only when the server says it twice, hours apart, and the key is kept: if that was our mistake
///   (a misconfigured server), the daily check that follows unlocks every Mac again by itself.
/// - A Mac that used CineNotch before it was paid (`priorInstall`) is an early supporter: free for good.
@MainActor
public final class LicenseManager: ObservableObject {
    public static let revalidateInterval: TimeInterval = 14 * 86400
    public static let reminderAfter: TimeInterval = 45 * 86400
    static let retryAfterFailure: TimeInterval = 6 * 3600
    /// How long a first "not valid" waits for its confirmation.
    static let confirmRefusalAfter: TimeInterval = 6 * 3600
    /// How often a locked Mac with a key asks whether it's valid again.
    static let recheckRevokedEvery: TimeInterval = 86400
    static let pollEvery: TimeInterval = 3600

    @Published public private(set) var state: LicenseState = .off
    @Published public private(set) var isBusy = false
    /// The last thing worth telling the user (an error from activating, "Activated", and so on).
    @Published public private(set) var message: String?

    public let configuration: LicenseConfiguration

    private let store: LicenseStoring
    private let server: LicenseServing
    private let deviceID: String
    private let deviceLabel: String
    private let now: () -> Date
    private var stored: StoredLicense?
    private var nextAttempt = Date.distantPast
    private var timer: Timer?
    /// Whether the Keychain has been read. Until then nothing is decided, written or sent.
    private var loaded = false
    private var loadAttempts = 0
    /// This Mac ran an earlier, free version: settings it left behind were found at launch.
    private let priorInstall: Bool
    /// `--debug-license-state`: the state is fixed and no server or Keychain is involved.
    private let fixedState: LicenseState?

    public init(configuration: LicenseConfiguration, store: LicenseStoring, server: LicenseServing,
                deviceID: String = DeviceIdentity.hash(), deviceLabel: String = DeviceIdentity.model(),
                now: @escaping () -> Date = Date.init, priorInstall: Bool = false, fixedState: LicenseState? = nil) {
        self.configuration = configuration
        self.priorInstall = priorInstall
        self.store = store
        self.server = server
        self.deviceID = deviceID
        self.deviceLabel = deviceLabel
        self.now = now
        self.fixedState = fixedState
        if let fixedState {
            state = fixedState
        } else if configuration.isEnforced {
            // Nothing is read until `start()`; until then the app shows the locked state rather than flashing unlocked.
            state = .unlicensed(.never)
        }
    }

    /// Only a build with licensing on can be locked.
    public var isEnforced: Bool { configuration.isEnforced || fixedState != nil && fixedState != .off }

    /// What gates the app's core features.
    public var isUnlocked: Bool { state.isUnlocked }

    /// Whether `state` is a decision (the Keychain was read, or the state is pinned) rather than the locked placeholder
    /// shown until then. The trial waits for this, so a licensed Mac never starts one.
    public var isStateKnown: Bool { fixedState != nil || loaded }

    // MARK: Lifecycle

    /// Reads what's stored, checks it offline, and schedules the soft re-validation.
    public func start() {
        guard fixedState == nil, configuration.isEnforced else { return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: Self.pollEvery, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.loaded { await self.revalidateIfDue() } else { self.load() }
                }
            }
            timer?.tolerance = 300
        }
        load()
    }

    /// The Keychain can refuse for a moment (locked right after login, say). That's never read as "not paid":
    /// the state stays as it was and it tries again shortly.
    private func load() {
        do {
            if try isEarlySupporter() { return }
            stored = try store.load()
            loaded = true
            state = evaluate(stored)
            Task { await revalidateIfDue() }
        } catch {
            loadAttempts += 1
            LicenseLog.write("license: Keychain not readable (\(error)), trying again")
            guard loadAttempts < 20 else { return }
            let delay = min(5 * Double(loadAttempts), 60)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                self?.retryLoad()
            }
        }
    }

    private func retryLoad() {
        if !loaded { load() }
    }

    /// Decided once per Mac, at the first launch of a build with licensing on: did this Mac use CineNotch before?
    private func isEarlySupporter() throws -> Bool {
        var decision = try store.loadEarlyAccess()
        if decision == nil {
            let made = EarlyAccess(isEarlySupporter: priorInstall, decidedAt: now())
            // If this can't be saved, nothing is decided: the next try still has this launch's evidence.
            try store.saveEarlyAccess(made)
            decision = made
            LicenseLog.write("license: \(priorInstall ? "used before CineNotch was paid: free for good" : "new on this Mac")")
        }
        guard let decision, decision.isEarlySupporter else { return false }
        loaded = true
        state = .earlySupporter(since: decision.decidedAt)
        return true
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The offline check: a signed token for this Mac and this key.
    func evaluate(_ license: StoredLicense?) -> LicenseState {
        guard let license else { return .unlicensed(.never) }
        if license.revokedAt != nil { return .unlicensed(.revoked) }
        guard let publicKey = configuration.publicKey, let claims = try? LicenseToken.verify(license.token, publicKey: publicKey),
              claims.dh == deviceID, claims.kh == LicenseHash.sha256Hex(license.key), claims.iid == license.instanceID else {
            return .unlicensed(.storedInvalid)
        }
        let n = now()
        let stale = n.timeIntervalSince(license.lastValidatedAt) > Self.reminderAfter || n > claims.expiresAt
        return .licensed(LicenseSummary(keyHint: Self.hint(license.key), activatedAt: license.activatedAt,
                                        lastValidatedAt: license.lastValidatedAt, needsReconnect: stale))
    }

    static func hint(_ key: String) -> String { "…" + key.suffix(4) }

    // MARK: Actions

    /// Activates this Mac with a key from the purchase email. Returns true when it worked.
    @discardableResult
    public func activate(key rawKey: String) async -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard fixedState == nil else {
            message = "Debug state: no license server."
            return false
        }
        guard configuration.isEnforced else { return false }
        guard loaded else {
            message = "CineNotch couldn't read its license from the Keychain yet. Try again in a moment."
            return false
        }
        guard !key.isEmpty else {
            message = "Paste the license key from your purchase email."
            return false
        }
        // A background check may be running: wait for it instead of ignoring the click.
        while isBusy { try? await Task.sleep(nanoseconds: 100_000_000) }
        isBusy = true
        defer { isBusy = false }
        do {
            let held = stored?.key == key ? stored?.instanceID : nil
            let grant = try await server.activate(key: key, deviceID: deviceID, deviceLabel: deviceLabel, instanceID: held)
            let license = try accept(grant, key: key, activatedAt: now())
            try? store.save(license)
            stored = license
            state = evaluate(license)
            message = "CineNotch is activated on this Mac."
            LicenseLog.write("license: activated")
            return true
        } catch let error as LicenseServerError {
            message = Self.text(for: error, supportEmail: configuration.supportEmail)
            LicenseLog.write("license: activation refused: \(error)")
        } catch {
            message = "The license server's answer couldn't be verified. Update CineNotch and try again."
            LicenseLog.write("license: activation answer didn't verify")
        }
        return false
    }

    /// Frees this Mac's slot, then forgets the license here.
    @discardableResult
    public func deactivate() async -> Bool {
        guard fixedState == nil, let license = stored, !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            try await server.deactivate(key: license.key, instanceID: license.instanceID, deviceID: deviceID)
        } catch let error as LicenseServerError where error == .notFound || error == .revoked {
            // Already gone on the server: nothing left to free.
        } catch let error as LicenseServerError {
            message = error == .unavailable || error == .notEnabled
                ? "Couldn't reach the license server, so this Mac's slot wasn't freed. Try again when you're online."
                : Self.text(for: error, supportEmail: configuration.supportEmail)
            return false
        } catch {
            return false
        }
        forget()
        message = "CineNotch is deactivated on this Mac. You can activate it on another one."
        LicenseLog.write("license: deactivated")
        return true
    }

    /// Removes the license from this Mac without telling the server (offline, or the server can't be reached).
    /// The slot stays used until it's freed from another place.
    public func forgetLocally() {
        guard fixedState == nil else { return }
        forget()
        message = "The license was removed from this Mac."
    }

    private func forget() {
        store.clear()
        stored = nil
        state = .unlicensed(.never)
    }

    /// A locked Mac that still has its key can ask again (Settings → License → Check Again).
    public var canRecheck: Bool { stored?.revokedAt != nil }

    /// The soft re-validation. Does nothing unless it's due (or `force`). Also runs, about daily, for a Mac that was
    /// locked by the server but kept its key.
    public func revalidateIfDue(force: Bool = false) async {
        guard fixedState == nil, let license = stored, !isBusy else { return }
        let wasRevoked = license.revokedAt != nil
        guard wasRevoked || state.isLicensed else { return }
        let n = now()
        let due = wasRevoked || license.refusedAt != nil || n.timeIntervalSince(license.lastValidatedAt) >= Self.revalidateInterval
        guard force || (due && n >= nextAttempt) else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let grant = try await server.validate(key: license.key, instanceID: license.instanceID, deviceID: deviceID)
            var renewed = try accept(grant, key: license.key, activatedAt: license.activatedAt)
            renewed.lastValidatedAt = now()
            try? store.save(renewed)
            stored = renewed
            state = evaluate(renewed)
            LicenseLog.write(wasRevoked ? "license: valid again, unlocked" : "license: checked, still valid")
            if force || wasRevoked { message = wasRevoked ? "Your license is valid again." : "Your license is valid." }
        } catch let error as LicenseServerError where error.isFinal {
            refused(license, error: error, at: n, force: force)
        } catch {
            // No network, the server is busy, or its answer wasn't one we can use: keep working, try again later.
            nextAttempt = now().addingTimeInterval(wasRevoked ? Self.recheckRevokedEvery : Self.retryAfterFailure)
            if force { message = wasRevoked ? "Couldn't reach the license server. Try again later."
                                            : "Couldn't reach the license server. Your license still works." }
            LicenseLog.write("license: check failed, will retry (\(error))")
        }
    }

    /// The server said "not valid". The first time it's only noted; repeated hours later it locks, keeping the key.
    private func refused(_ license: StoredLicense, error: LicenseServerError, at n: Date, force: Bool) {
        var updated = license
        if license.revokedAt != nil {
            nextAttempt = n.addingTimeInterval(Self.recheckRevokedEvery)
            if force { message = Self.text(for: error, supportEmail: configuration.supportEmail) }
            LicenseLog.write("license: still not valid (\(error))")
            return
        }
        if let first = license.refusedAt, n.timeIntervalSince(first) >= Self.confirmRefusalAfter {
            updated.revokedAt = n
            state = .unlicensed(.revoked)
            nextAttempt = n.addingTimeInterval(Self.recheckRevokedEvery)
            message = Self.text(for: error, supportEmail: configuration.supportEmail)
            LicenseLog.write("license: no longer valid, confirmed (\(error))")
        } else {
            if updated.refusedAt == nil { updated.refusedAt = n }
            nextAttempt = n.addingTimeInterval(Self.confirmRefusalAfter)
            if force { message = "The license server says this license isn't valid. CineNotch keeps working and checks again in a few hours." }
            LicenseLog.write("license: server says not valid (\(error)), will confirm later")
        }
        try? store.save(updated)
        stored = updated
    }

    /// The server's token must be signed by us, for this key and this Mac.
    private func accept(_ grant: LicenseGrant, key: String, activatedAt: Date) throws -> StoredLicense {
        guard let publicKey = configuration.publicKey else { throw LicenseTokenError.badSignature }
        let claims = try LicenseToken.verify(grant.token, publicKey: publicKey)
        guard claims.dh == deviceID, claims.kh == LicenseHash.sha256Hex(key), claims.iid == grant.instanceID else {
            throw LicenseTokenError.badSignature
        }
        return StoredLicense(key: key, instanceID: grant.instanceID, token: grant.token, activatedAt: activatedAt, lastValidatedAt: now())
    }

    static func text(for error: LicenseServerError, supportEmail: String) -> String {
        switch error {
        case .notFound: return "That license key wasn't found. Check it against your purchase email and try again."
        case .revoked: return "This license is no longer valid. If you were refunded, that's why. Otherwise write to \(supportEmail)."
        case .limitReached: return "This license is already active on the most Macs it allows. Deactivate it on another Mac, or write to \(supportEmail)."
        case .rateLimited: return "Too many tries. Wait a minute and try again."
        case .notEnabled: return "Activation isn't switched on yet. Try again soon."
        case .invalidRequest: return "That doesn't look like a license key."
        case .unavailable: return "Couldn't reach the license server. Check your connection and try again."
        }
    }
}

/// The library has no UI and no logger of its own: the app plugs its log in.
public enum LicenseLog {
    nonisolated(unsafe) public static var sink: (String) -> Void = { _ in }
    static func write(_ message: String) { sink(message) }
}
