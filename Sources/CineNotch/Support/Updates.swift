import AppKit
import Security
import Sparkle

/// In-app updates with Sparkle: a daily check of the appcast on cinenotch.cam (`SUFeedURL` in
/// Info.plist), "Check for Updates…" in the menu, and a switch in Settings → General.
/// Only builds signed with Developer ID update themselves: a local build would otherwise offer to
/// replace itself with the release.
@MainActor
final class Updates: NSObject, SPUStandardUserDriverDelegate {
    /// False for local builds: no checks, and the menu and Settings hide the update controls.
    let isAvailable = Updates.isDeveloperIDSigned
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil,
                                                               userDriverDelegate: self)

    func start() {
        guard isAvailable else {
            Log.info("updates: off for this build (not signed with Developer ID)")
            return
        }
        controller.startUpdater()
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get { isAvailable && controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    // MARK: SPUStandardUserDriverDelegate

    // CineNotch lives in the menu bar, so a scheduled check has no window of its own to show the
    // update in: bring the app forward when Sparkle shows one.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                               forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard handleShowingUpdate, !state.userInitiated else { return }
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: Signature

    /// A Developer ID signature carries a team identifier; the local "CineNotch Dev" one doesn't.
    private static var isDeveloperIDSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return false }
        return dict[kSecCodeInfoTeamIdentifier as String] is String
    }
}
