import AppKit

@main
enum CineNotchApp {
    @MainActor static func main() {
        // Before anything this launch could write the settings it looks for.
        Licensing.notePriorInstall()
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
