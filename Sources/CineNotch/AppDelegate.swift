import AppKit
import CineNotchLicense
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options = LaunchOptions.current
    private let pip = PiPController()
    private let gaze = GazeController()
    private let updates = Updates()
    private lazy var license = Licensing.makeManager(options: options)
    /// The license, or an active 7-day trial on a Mac that was never activated: what the core features go by.
    private lazy var gate = FeatureGate(license: license, trial: Licensing.makeTrialManager(options: options, license: license))
    private let loginItem = LoginItem()
    private var hotKeys: HotKeys?
    private var island: IslandController?
    private var calibrator: GazeCalibrator?
    private var glanceInvite: GlanceInvite?
    private var tester: GazeTester?
    private var hud: GazeHUD?
    private var statusMenu: StatusMenu?
    private var onboarding: Onboarding?
    private var settings: SettingsWindow?
    private var collapsePause: CollapsePause?
    private var awayPause: AwayPause?
    private var onlookerHide: OnlookerHide?
    private var lockPill: LockPill?
    private var cancellables = Set<AnyCancellable>()
    private var signalSources: [DispatchSourceSignal] = []
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()
        Log.info("launch \(Bundle.main.bundlePath) args=\(CommandLine.arguments.dropFirst())")
        let island = IslandController(pip: pip, options: options)
        // The demo plays its own glances; the camera stays out of it.
        if !options.debugDemo { island.attachGaze(gaze) }
        gaze.islandRect = { [weak island] in island?.expandedRectNormalized() ?? .zero }
        gaze.screenFrame = { [weak island] in island?.metrics.screenFrame ?? .zero }
        self.island = island
        let calibrator = GazeCalibrator(gaze: gaze, island: island)
        self.calibrator = calibrator
        // The demo plays its own glances, so it never asks for a calibration.
        if !options.debugDemo {
            glanceInvite = GlanceInvite(gaze: gaze, island: island, pip: pip, calibrate: { calibrator.start() })
        }
        let tester = GazeTester(gaze: gaze, island: island)
        self.tester = tester
        let hud = GazeHUD(gaze: gaze)
        self.hud = hud
        let collapsePause = CollapsePause(pip: pip, island: island)
        self.collapsePause = collapsePause
        let awayPause = AwayPause(pip: pip, island: island, gaze: gaze)
        self.awayPause = awayPause
        let onlookerHide = OnlookerHide(pip: pip, island: island, gaze: gaze)
        self.onlookerHide = onlookerHide
        let hotKeys = HotKeys()
        hotKeys.perform = { [weak self, weak island] action in
            guard let self, pip.isActive else { return }
            switch action {
            case .togglePlay: pip.togglePlay()
            case .skipBack: pip.skip(forward: false)
            case .skipForward: pip.skip(forward: true)
            case .toggleIsland: island?.toggleFromKeyboard()
            case .bigger: island?.stepVideoSize(bigger: true)
            case .smaller: island?.stepVideoSize(bigger: false)
            }
        }
        self.hotKeys = hotKeys
        let settings = SettingsWindow(gaze: gaze, island: island, collapsePause: collapsePause, awayPause: awayPause,
                                      onlookerHide: onlookerHide, loginItem: loginItem, hotKeys: hotKeys, updates: updates, license: license,
                                      gate: self.gate, calibrate: { calibrator.start() })
        self.settings = settings
        let onboarding = Onboarding()
        onboarding.onPermissionsGranted = { [weak self] in self?.startEngine() }
        onboarding.onOpenAtLogin = { [loginItem] open in if open != loginItem.isEnabled { loginItem.set(open) } }
        onboarding.onSetUpGlance = { [weak self] in
            self?.gaze.isEnabled = true
            calibrator.start()
        }
        self.onboarding = onboarding

        // Licensing: off in every build until Info.plist says otherwise, and then nothing in this block does anything.
        // The gate is made before `license.start()`, so it sees the first real license state and can start the trial.
        let license = self.license
        let gate = self.gate
        pip.setLocked(!gate.isUnlocked)
        gate.$isUnlocked
            .map { !$0 }
            .removeDuplicates()
            .sink { [pip] locked in pip.setLocked(locked) }
            .store(in: &cancellables)
        if license.isEnforced {
            lockPill = LockPill(gate: gate, pip: pip,
                                enterKey: { settings.show(.license) },
                                buy: { Licensing.open(gate.buyURL) })
        }
        license.start()
        gate.noteLicenseReady()
        if license.configuration.storeAccount == "debug-activation", options.debugLicenseActivate != nil || options.debugLicenseDeactivate {
            Task { [options] in
                if let key = options.debugLicenseActivate { await license.activate(key: key) }
                if options.debugLicenseDeactivate { await license.deactivate() }
                Log.info("license: debug action done: \(license.state), \(license.message ?? "no message")")
            }
        }

        pip.$isActive
            .sink { [weak self] active in self?.gaze.isPiPActive = active && !(self?.options.debugDemo ?? false) }
            .store(in: &cancellables)
        gaze.$isHUDVisible
            .removeDuplicates()
            .sink { visible in visible ? hud.show() : hud.hide() }
            .store(in: &cancellables)

        statusMenu = StatusMenu(pip: pip, gaze: gaze, island: island, collapsePause: collapsePause, awayPause: awayPause,
                                onlookerHide: onlookerHide, updates: updates, gate: gate,
                                thumbnail: { [weak island] in island?.thumbnail() },
                                showPermissions: { onboarding.show(.permissions) },
                                showSettings: { settings.show() },
                                showLicense: { settings.show(.license) },
                                calibrate: { calibrator.start() },
                                testGaze: { tester.start() })
        if options.evaluateGaze {
            Task {
                await gaze.evaluateRecordedTests()
                NSApp.terminate(nil)
            }
            return
        }
        Task { [gaze] in await gaze.loadStoredCalibration() }
        if let dir = options.debugOverlayDir {
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await GazeOverlay.preview(island: island, into: dir)
            }
        }
        if let dir = options.debugWindowsDir {
            Task { await previewWindows(into: dir) }
        }
        installSignalHandlers()
        updates.start()
        if Permissions.allGranted || options.debugFakePiP {
            startEngine()
            if !Onboarding.isDone, !options.debugFakePiP { onboarding.show(.ready) }
        } else {
            onboarding.show(Onboarding.resumeStep ?? .welcome)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the PiP window stranded in the corner.
        pip.release()
    }

    private func startEngine() {
        guard !started else { return }
        started = true
        island?.start()
        pip.start()
        if options.debugGaze { gaze.isHUDVisible = true }
        if options.debugDemo, let island { DemoScript.run(pip: pip, island: island, recordTo: options.debugRecordURL) }
    }

    /// `--debug-windows <dir>`: every onboarding step, the camera-free Settings tabs and the calibration invite, one picture each.
    private func previewWindows(into dir: URL) async {
        guard let onboarding, let settings else { return }
        func snap(_ number: Int?, _ name: String) async {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let number { DebugSnapshot.captureWindow(CGWindowID(number), to: dir.appendingPathComponent("\(name).png")) }
            try? await Task.sleep(nanoseconds: 700_000_000)
        }
        for step in Onboarding.Step.allCases {
            onboarding.show(step)
            await snap(onboarding.windowNumber, "onboarding-\(step)")
        }
        onboarding.close()
        for tab in [SettingsWindow.Tab.general, .keyboard] + (license.isEnforced ? [.license] : []) + [.about] {
            settings.show(tab)
            await snap(settings.windowNumber, "settings-\(tab)")
        }
        settings.close()
        if let lockPill {
            await snap(lockPill.showForPreview(), "lock-pill")
            lockPill.hidePreview()
        }
        GlanceInvite.renderPreviews(into: dir)
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
