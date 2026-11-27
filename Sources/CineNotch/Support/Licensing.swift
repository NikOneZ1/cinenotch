import AppKit
import CineNotchLicense
import Combine
import Foundation

/// Sets licensing up from Info.plist (`LicensingEnabled`, see docs/LICENSING.md) and the `--debug-license-*` options.
/// With `LicensingEnabled` false (every build until the paid version ships) the manager is inert:
/// the app is unrestricted, nothing is read from the Keychain and nothing is sent anywhere.
enum Licensing {
    /// This Mac ran a CineNotch from before it was paid, so it's an early supporter (free for good). The evidence is
    /// what earlier versions leave in the defaults: onboarding (every version since 0.1.0) and Sparkle's first-launch
    /// flag (0.2.0 on). `notePriorInstall` reads it at the very start of `main`, before this launch writes any of it.
    @MainActor private(set) static var priorInstall = false

    @MainActor static func notePriorInstall() {
        let defaults = UserDefaults.standard
        priorInstall = ["onboardingDone", "onboardingResume", "SUHasLaunchedBefore"].contains { defaults.object(forKey: $0) != nil }
    }

    @MainActor static func makeManager(options: LaunchOptions) -> LicenseManager {
        LicenseLog.sink = { Log.info($0) }
        let info = Bundle.main.infoDictionary
        var configuration = LicenseConfiguration(info: info,
                                                 enabledOverride: options.debugLicenseEnabled ? true : nil,
                                                 serverOverride: options.debugLicenseServer,
                                                 publicKeyOverride: options.debugLicensePublicKey)
        let isDebug = isDebugRun(options)
        if isDebug { configuration.storeAccount = debugAccount }
        let store = KeychainLicenseStore(account: configuration.storeAccount)
        if isDebug, options.debugLicenseReset {
            store.clear()
            store.clearEarlyAccess()
        }
        if case .misconfigured(let reason) = configuration.mode {
            Log.info("license: LicensingEnabled is on but \(reason), so the app stays unrestricted")
        }
        let fixed = options.debugLicenseState.flatMap(fixedState)
        if options.debugLicenseState != nil, fixed == nil {
            Log.info("license: unknown --debug-license-state '\(options.debugLicenseState ?? "")'")
        }
        let manager = LicenseManager(configuration: configuration,
                                     store: store,
                                     server: HTTPLicenseServer(baseURL: configuration.serverURL),
                                     // A debug run on a Mac that had CineNotch would otherwise never see the paid flow.
                                     priorInstall: isDebug ? options.debugLicensePriorInstall : priorInstall,
                                     fixedState: fixed)
        Log.info("license: \(manager.isEnforced ? "on" : "off")\(isDebug ? " (debug)" : "")")
        return manager
    }

    /// Keychain account of debug runs (`--debug-license-enabled`, `-server`, `-public-key`), so they never touch a real
    /// activation. Their trial is `debug-activation.trial` with its own defaults keys.
    static let debugAccount = "debug-activation"

    static func isDebugRun(_ options: LaunchOptions) -> Bool {
        options.debugLicenseEnabled || options.debugLicenseServer != nil || options.debugLicensePublicKey != nil
    }

    /// The 7-day trial. Built always, but it reads and writes nothing until `FeatureGate` starts it, which only happens
    /// with licensing on and a Mac that was never activated.
    @MainActor static func makeTrialManager(options: LaunchOptions, license: LicenseManager) -> TrialManager {
        // Only ever the debug record: a real trial can't be reset from the command line.
        if options.debugTrialReset || options.debugLicenseReset {
            MirroredTrialStore.keychainAndDefaults(account: debugAccount).clear()
            Log.info("trial: debug trial reset")
        }
        let store: TrialStoring = options.debugLicenseState != nil
            // A pinned license state reads no Keychain, and neither does its trial: a fresh 7 days every run.
            ? MemoryTrialStore()
            : MirroredTrialStore.keychainAndDefaults(account: license.configuration.storeAccount)
        return TrialManager(store: store, fixedDaysLeft: options.debugTrialDaysLeft)
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
        case "early": return .earlySupporter(since: Date().addingTimeInterval(-90 * day))
        default: return nil
        }
    }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

/// What the app's core features (docking, the glance, the menu's controls) go by: the license, or an active trial on a Mac
/// that was never activated. `LicenseState.isUnlocked` stays the license alone.
@MainActor
final class FeatureGate: ObservableObject {
    let license: LicenseManager
    let trial: TrialManager
    @Published private(set) var isUnlocked: Bool
    /// The trial as the UI shows it: always `.inactive` for licensed, early-supporter, revoked and damaged licenses.
    @Published private(set) var trialStatus: TrialStatus
    private var decided = false
    private var cancellables = Set<AnyCancellable>()

    init(license: LicenseManager, trial: TrialManager) {
        self.license = license
        self.trial = trial
        isUnlocked = TrialAccess.isUnlocked(license.state, trial: trial.status)
        trialStatus = TrialAccess.visibleStatus(license.state, trial: trial.status)
        // Values come from the publishers, not the objects: @Published sends before the property changes.
        license.$state
            .combineLatest(trial.$status)
            .sink { [weak self] state, status in
                guard let self else { return }
                let unlocked = TrialAccess.isUnlocked(state, trial: status)
                if unlocked != isUnlocked { isUnlocked = unlocked }
                let visible = TrialAccess.visibleStatus(state, trial: status)
                if visible != trialStatus { trialStatus = visible }
            }
            .store(in: &cancellables)
        license.$state
            .sink { [weak self] state in self?.startTrialIfNew(state) }
            .store(in: &cancellables)
    }

    /// Call after `license.start()` so the trial still starts when the license state doesn't change
    /// (the placeholder is already "never activated"). The `$state` sink covers later reads too.
    func noteLicenseReady() {
        startTrialIfNew(license.state)
    }

    /// Decided once per launch, on the first real license state (not the locked placeholder before the Keychain is read):
    /// only a Mac with licensing on that was never activated starts (or resumes) its trial. Licensed, early-supporter,
    /// revoked and damaged ones never touch it. Activating later hides the trial; nothing is deleted.
    private func startTrialIfNew(_ state: LicenseState) {
        guard !decided, license.isEnforced, license.isStateKnown else { return }
        decided = true
        if TrialAccess.appliesTo(state) { trial.start() }
    }

    /// Never activated: the trial's "Buy license" / "Enter key". Revoked or damaged keep "Buy CineNotch…".
    var isNeverActivated: Bool { license.isEnforced && TrialAccess.appliesTo(license.state) }

    var buyURL: URL { isNeverActivated ? TrialManager.buyURL : license.configuration.buyURL }
}
