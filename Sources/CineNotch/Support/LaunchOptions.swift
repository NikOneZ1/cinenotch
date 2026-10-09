import Foundation

/// Developer switches, passed as launch arguments (`open CineNotch.app --args --debug-notch`).
struct LaunchOptions {
    /// Pretend the screen has a notch, to work on the notch layout on any Mac.
    var debugNotch = false
    /// Expand and collapse the island on a timer instead of following the mouse.
    var debugCycle = false
    /// Save screenshots of the island around every state change into this directory.
    var debugSnapshotDir: URL?
    /// Save the island window alone (transparent background) once each state settles, for mockups.
    var debugIslandDir: URL?
    /// Open the gaze debug panel on launch.
    var debugGaze = false
    /// Score every gaze engine on the recorded gaze tests, log the results and quit.
    var evaluateGaze = false
    /// Show each overlay screen briefly and save screenshots of it into this directory.
    var debugOverlayDir: URL?
    /// A generated video stands in for Safari's Picture in Picture, so the island works without one.
    var debugFakePiP = false
    /// Open each onboarding step and Settings tab, save a picture of each window into this directory, close them.
    var debugWindowsDir: URL?
    /// Play a fixed scene on the fake video (see DemoScript).
    var debugDemo = false
    /// With `debugDemo`: record the island window into this movie, then quit.
    var debugRecordURL: URL?
    /// Island animations at a fifth of their speed, to look at them (and snapshot them) frame by frame.
    var debugSlowMotion = false

    static let current: LaunchOptions = {
        var options = LaunchOptions()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--debug-notch": options.debugNotch = true
            case "--debug-cycle": options.debugCycle = true
            case "--debug-gaze": options.debugGaze = true
            case "--evaluate-gaze": options.evaluateGaze = true
            case "--debug-fake-pip": options.debugFakePiP = true
            case "--debug-demo":
                options.debugDemo = true
                options.debugFakePiP = true
            case "--debug-record":
                if let path = args.next() { options.debugRecordURL = URL(fileURLWithPath: path) }
            case "--debug-slow-motion": options.debugSlowMotion = true
            case "--debug-overlay":
                if let path = args.next() { options.debugOverlayDir = URL(fileURLWithPath: path) }
            case "--debug-windows":
                if let path = args.next() { options.debugWindowsDir = URL(fileURLWithPath: path) }
            case "--debug-snapshots":
                if let path = args.next() { options.debugSnapshotDir = URL(fileURLWithPath: path) }
            case "--debug-island-png":
                if let path = args.next() { options.debugIslandDir = URL(fileURLWithPath: path) }
            default: break
            }
        }
        return options
    }()
}
