import CineNotchGeometry
import Foundation

/// Developer switches, passed as launch arguments (`open CineNotch.app --args --debug-notch`).
struct LaunchOptions {
    /// Pretend the screen has a notch, to work on the notch layout on any Mac. Same as `--debug-layout notch`.
    var debugNotch = false
    /// `--debug-layout <notch|island|none>`: use this layout whatever the screen reports. "island" on a Mac without
    /// one uses a synthetic pill and top gap from the menu bar strip (see `CutoutClassifier.forced`).
    var debugLayout: CutoutKind?
    /// The layout to force, if any: `--debug-layout` wins over `--debug-notch`.
    var forcedLayout: CutoutKind? { debugLayout ?? (debugNotch ? .notch : nil) }
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
    /// `--debug-demo-scene <name>`: which scene the demo plays, "tour" (the default), "keys" or "sizes".
    var debugDemoScene = "tour"
    /// With `debugDemo`: record the island window into this movie, then quit.
    var debugRecordURL: URL?
    /// Island animations at a fifth of their speed, to look at them (and snapshot them) frame by frame.
    var debugSlowMotion = false

    /// Licensing is off in every build until `LicensingEnabled` is switched on in Info.plist. These four try it without that.
    /// `--debug-license-enabled`: licensing on, with its own Keychain item so a real activation is never touched.
    var debugLicenseEnabled = false
    /// `--debug-license-server <url>`: where activation goes, for a local Worker (`wrangler dev`), e.g. http://127.0.0.1:8787.
    var debugLicenseServer: URL?
    /// `--debug-license-public-key <base64>`: the Ed25519 public key that checks the tokens, for a local Worker's test keys.
    var debugLicensePublicKey: String?
    /// `--debug-license-state <off|unlicensed|revoked|licensed|stale|early>`: pin the license state, to see the locked island, the
    /// menu and the License tab. No server, no Keychain.
    var debugLicenseState: String?
    /// `--debug-license-prior-install`: debug runs count as a new install unless this says it used an earlier version.
    var debugLicensePriorInstall = false
    /// `--debug-license-reset`: forget the debug activation and the debug early-supporter decision first.
    var debugLicenseReset = false
    /// `--debug-license-activate <key>` / `--debug-license-deactivate`: do it at launch, as the License tab would. Debug Keychain only.
    var debugLicenseActivate: String?
    var debugLicenseDeactivate = false

    static let current: LaunchOptions = {
        var options = LaunchOptions()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--debug-notch": options.debugNotch = true
            case "--debug-layout":
                if let name = args.next() { options.debugLayout = CutoutKind(rawValue: name) }
            case "--debug-cycle": options.debugCycle = true
            case "--debug-gaze": options.debugGaze = true
            case "--evaluate-gaze": options.evaluateGaze = true
            case "--debug-fake-pip": options.debugFakePiP = true
            case "--debug-demo":
                options.debugDemo = true
                options.debugFakePiP = true
            case "--debug-demo-scene":
                if let name = args.next() { options.debugDemoScene = name }
            case "--debug-record":
                if let path = args.next() { options.debugRecordURL = URL(fileURLWithPath: path) }
            case "--debug-license-enabled": options.debugLicenseEnabled = true
            case "--debug-license-server":
                if let text = args.next() { options.debugLicenseServer = URL(string: text) }
            case "--debug-license-public-key":
                if let key = args.next() { options.debugLicensePublicKey = key }
            case "--debug-license-state":
                if let name = args.next() { options.debugLicenseState = name }
            case "--debug-license-prior-install": options.debugLicensePriorInstall = true
            case "--debug-license-reset": options.debugLicenseReset = true
            case "--debug-license-activate":
                if let key = args.next() { options.debugLicenseActivate = key }
            case "--debug-license-deactivate": options.debugLicenseDeactivate = true
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
