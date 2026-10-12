import AppKit
import Combine
import SwiftUI

/// Menu bar icon: what's playing, glance settings, the PiP window, Settings, quit.
/// Holding ⌥ while opening it adds the developer items.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let pip: PiPController
    private let gaze: GazeController
    private let collapsePause: CollapsePause
    private let updates: Updates
    private let thumbnail: () -> CGImage?
    private let showPermissions: () -> Void
    private let showSettings: () -> Void
    private let calibrate: () -> Void
    private let testGaze: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(pip: PiPController, gaze: GazeController, collapsePause: CollapsePause, updates: Updates,
         thumbnail: @escaping () -> CGImage?,
         showPermissions: @escaping () -> Void, showSettings: @escaping () -> Void,
         calibrate: @escaping () -> Void, testGaze: @escaping () -> Void) {
        self.pip = pip
        self.gaze = gaze
        self.collapsePause = collapsePause
        self.updates = updates
        self.thumbnail = thumbnail
        self.showPermissions = showPermissions
        self.showSettings = showSettings
        self.calibrate = calibrate
        self.testGaze = testGaze
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        // The icon fills in while a video is docked.
        pip.$isActive
            .removeDuplicates()
            .sink { [weak self] active in self?.item.button?.image = StatusIcon.image(active: active) }
            .store(in: &cancellables)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let developer = NSEvent.modifierFlags.contains(.option)

        menu.addItem(nowPlaying())
        menu.addItem(.separator())

        if !Permissions.allGranted {
            menu.addItem(makeItem("Allow Permissions…", #selector(openPermissions), symbol: "exclamationmark.triangle"))
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem.sectionHeader(title: "Glance at the Camera"))
        let gazeItem = makeItem("Reveal the Video", #selector(toggleGaze), symbol: "eye")
        gazeItem.state = gaze.isEnabled ? .on : .off
        menu.addItem(gazeItem)
        let sensitivities = NSMenu()
        for sensitivity in GazeSensitivity.allCases {
            let item = makeItem(sensitivity.title, #selector(selectSensitivity(_:)))
            item.representedObject = sensitivity.rawValue
            item.state = sensitivity == gaze.sensitivity ? .on : .off
            sensitivities.addItem(item)
        }
        let sensitivityItem = makeItem("Sensitivity", nil, symbol: "dial.medium")
        sensitivityItem.submenu = sensitivities
        menu.addItem(sensitivityItem)
        menu.addItem(makeItem(gaze.isCalibrated ? "Recalibrate…" : "Calibrate…", #selector(startCalibration), symbol: "scope"))

        menu.addItem(.separator())
        let pauseItem = makeItem("Pause When the Island Closes", #selector(togglePausesWhenCollapsed), symbol: "pause.circle")
        pauseItem.state = collapsePause.isEnabled ? .on : .off
        menu.addItem(pauseItem)
        if pip.hasWindow {
            if pip.isReleased {
                menu.addItem(makeItem("Put the Video Back in the Island", #selector(dockWindow), symbol: "pip.enter"))
            } else {
                menu.addItem(makeItem("Pop Out the Video", #selector(releaseWindow), symbol: "pip.exit"))
            }
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
        if updates.isAvailable {
            menu.addItem(makeItem("Check for Updates…", #selector(checkForUpdates), symbol: "arrow.down.circle"))
        }
        menu.addItem(makeItem("Quit CineNotch", #selector(quit), key: "q", symbol: "power"))

        if developer { addDeveloperItems(to: menu) }
    }

    private func addDeveloperItems(to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Developer"))
        let hudItem = makeItem("Gaze Debug Panel", #selector(toggleHUD), symbol: "waveform.path.ecg")
        hudItem.state = gaze.isHUDVisible ? .on : .off
        menu.addItem(hudItem)
        menu.addItem(makeItem("Test Gaze Engines…", #selector(startGazeTest), symbol: "checklist"))
        if gaze.engineIDs.count > 1 {
            let engines = NSMenu()
            for id in gaze.engineIDs {
                let item = makeItem(GazeController.title(of: id), #selector(selectEngine(_:)))
                item.representedObject = id
                item.state = id == gaze.activeEngineID ? .on : .off
                if let report = gaze.reports[id] { item.toolTip = report.summary }
                engines.addItem(item)
            }
            let enginesItem = makeItem("Gaze Engine: \(gaze.activeEngineID)", nil, symbol: "cpu")
            enginesItem.submenu = engines
            menu.addItem(enginesItem)
        }
        menu.addItem(makeItem("Open Logs Folder", #selector(openLogs), symbol: "folder"))
    }

    private func nowPlaying() -> NSMenuItem {
        let state: NowPlayingCard.State
        if !Permissions.allGranted {
            state = .needsPermissions
        } else if pip.isActive {
            state = .docked(title: pip.title, thumbnail: thumbnail(), progress: pip.progress,
                            isPlaying: pip.features.playPause ? pip.isPlaying : nil)
        } else if pip.isReleased {
            state = .released(title: pip.title)
        } else {
            state = .waiting
        }
        let view = NSHostingView(rootView: NowPlayingCard(state: state))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let item = NSMenuItem()
        item.view = view
        return item
    }

    private func makeItem(_ title: String, _ action: Selector?, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return item
    }

    @objc private func dockWindow() { pip.dock() }
    @objc private func releaseWindow() { pip.release() }
    @objc private func openPermissions() { showPermissions() }
    @objc private func openSettings() { showSettings() }
    @objc private func checkForUpdates() { updates.checkForUpdates() }
    @objc private func startCalibration() { calibrate() }
    @objc private func startGazeTest() { testGaze() }

    @objc private func selectSensitivity(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let sensitivity = GazeSensitivity(rawValue: raw) {
            gaze.sensitivity = sensitivity
        }
    }

    @objc private func selectEngine(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { gaze.activeEngineID = id }
    }
    @objc private func toggleHUD() { gaze.isHUDVisible.toggle() }
    @objc private func togglePausesWhenCollapsed() { collapsePause.isEnabled.toggle() }

    @objc private func openLogs() {
        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs"))
    }

    @objc private func toggleGaze() {
        gaze.isEnabled.toggle()
        if gaze.isEnabled, !gaze.isCalibrated { calibrate() }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

/// The top of the menu: the docked video, or what to do to get one.
private struct NowPlayingCard: View {
    enum State {
        case needsPermissions
        case waiting
        case released(title: String)
        /// `isPlaying` is nil when the window doesn't tell (Chrome).
        case docked(title: String, thumbnail: CGImage?, progress: Double?, isPlaying: Bool?)
    }

    let state: State

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if case let .docked(_, _, progress, _) = state, let progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(.primary)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(width: 290, alignment: .leading)
    }

    @ViewBuilder private var artwork: some View {
        switch state {
        case let .docked(_, thumbnail?, _, isPlaying):
            Image(decorative: thumbnail, scale: 2)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 41)
                .saturation(isPlaying == false ? 0.2 : 1)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        default:
            Mascot(width: 54, awake: !isNeedsPermissions)
                .frame(width: 72, height: 41)
        }
    }

    private var isNeedsPermissions: Bool {
        if case .needsPermissions = state { return true }
        return false
    }

    private var title: String {
        switch state {
        case .needsPermissions: return "CineNotch needs two permissions"
        case .waiting: return "No video yet"
        case let .released(title), let .docked(title, _, _, _): return title.isEmpty ? "Picture in Picture" : title
        }
    }

    private var detail: String {
        switch state {
        case .needsPermissions: return "Allow them to dock the video."
        case .waiting: return "Start Picture in Picture in Safari or Chrome."
        case .released: return "Floating outside the island."
        case let .docked(_, _, _, isPlaying):
            guard let isPlaying else { return "In the island" }
            return isPlaying ? "Playing" : "Paused"
        }
    }
}
