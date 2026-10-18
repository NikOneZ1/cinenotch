import Foundation
import ServiceManagement

/// "Open at Login", through the system's login items (System Settings → General → Login Items).
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = false
    /// Registered, but the user switched it off in System Settings, so only they can allow it again.
    @Published private(set) var needsApproval = false

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        if (status == .enabled) != isEnabled { isEnabled = status == .enabled }
        if (status == .requiresApproval) != needsApproval { needsApproval = status == .requiresApproval }
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.info("open at login: \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
        refresh()
        Log.info("open at login: \(isEnabled)\(needsApproval ? " (needs approval in System Settings)" : "")")
    }

    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
