import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options = LaunchOptions.current
    private let pip = PiPController()
    private let gaze = GazeController()
    private var island: IslandController?
    private var calibrator: GazeCalibrator?
    private var tester: GazeTester?
    private var hud: GazeHUD?
    private var statusMenu: StatusMenu?
    private var onboarding: Onboarding?
    private var settings: SettingsWindow?
    private var collapsePause: CollapsePause?
    private var cancellables = Set<AnyCancellable>()
    private var signalSources: [DispatchSourceSignal] = []
    private var started = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("launch \(Bundle.main.bundlePath) args=\(CommandLine.arguments.dropFirst())")
        let island = IslandController(pip: pip, options: options)
        // The demo plays its own glances; the camera stays out of it.
        if !options.debugDemo { island.attachGaze(gaze) }
        gaze.islandRect = { [weak island] in island?.expandedRectNormalized() ?? .zero }
        gaze.screenFrame = { [weak island] in island?.metrics.screenFrame ?? .zero }
        self.island = island
        let calibrator = GazeCalibrator(gaze: gaze, island: island)
        self.calibrator = calibrator
        let tester = GazeTester(gaze: gaze, island: island)
        self.tester = tester
        let hud = GazeHUD(gaze: gaze)
        self.hud = hud
        let collapsePause = CollapsePause(pip: pip, island: island)
        self.collapsePause = collapsePause
        let settings = SettingsWindow(gaze: gaze, glow: island.glow, collapsePause: collapsePause,
                                      calibrate: { calibrator.start() })
        self.settings = settings
        let onboarding = Onboarding()
        onboarding.onPermissionsGranted = { [weak self] in self?.startEngine() }
        onboarding.onSetUpGlance = { [weak self] in
            self?.gaze.isEnabled = true
            calibrator.start()
        }
        self.onboarding = onboarding

        pip.$isActive
            .sink { [weak self] active in self?.gaze.isPiPActive = active && !(self?.options.debugDemo ?? false) }
            .store(in: &cancellables)
        gaze.$isHUDVisible
            .removeDuplicates()
            .sink { visible in visible ? hud.show() : hud.hide() }
            .store(in: &cancellables)

        statusMenu = StatusMenu(pip: pip, gaze: gaze, collapsePause: collapsePause, thumbnail: { [weak island] in island?.thumbnail() },
                                showPermissions: { onboarding.show(.permissions) },
                                showSettings: { settings.show() },
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

    /// `--debug-windows <dir>`: every onboarding step and the camera-free Settings tabs, one picture each.
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
        for tab in [SettingsWindow.Tab.general, .about] {
            settings.show(tab)
            await snap(settings.windowNumber, "settings-\(tab)")
        }
        settings.close()
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
