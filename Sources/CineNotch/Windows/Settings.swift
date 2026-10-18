import AVFoundation
import AppKit
import Combine
import SwiftUI

/// Settings: General (permissions, startup, the island, updates), Gaze (camera preview, sensitivity,
/// calibration), Keyboard (shortcuts), About.
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    enum Tab: Int { case general, gaze, keyboard, about }

    private let gaze: GazeController
    private let glow: AmbientGlow
    private let collapsePause: CollapsePause
    private let awayPause: AwayPause
    private let onlookerHide: OnlookerHide
    private let loginItem: LoginItem
    private let hotKeys: HotKeys
    private let updates: Updates
    private let calibrate: () -> Void
    private var window: NSWindow?
    private var tabs: NSTabViewController?

    init(gaze: GazeController, glow: AmbientGlow, collapsePause: CollapsePause, awayPause: AwayPause,
         onlookerHide: OnlookerHide, loginItem: LoginItem, hotKeys: HotKeys, updates: Updates,
         calibrate: @escaping () -> Void) {
        self.gaze = gaze
        self.glow = glow
        self.collapsePause = collapsePause
        self.awayPause = awayPause
        self.onlookerHide = onlookerHide
        self.loginItem = loginItem
        self.hotKeys = hotKeys
        self.updates = updates
        self.calibrate = calibrate
    }

    func show(_ tab: Tab = .general) {
        if window == nil { makeWindow() }
        tabs?.selectedTabViewItemIndex = tab.rawValue
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        gaze.isPreviewVisible = false
    }

    func close() { window?.close() }

    var windowNumber: Int? { window?.windowNumber }

    private func makeWindow() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let general = GeneralPane(glow: glow, collapsePause: collapsePause, awayPause: awayPause,
                                  onlookerHide: onlookerHide, loginItem: loginItem, updates: updates)
        tabs.addTabViewItem(item("General", symbol: "gearshape", general))
        tabs.addTabViewItem(item("Gaze", symbol: "eye", GazePane(gaze: gaze, calibrate: { [weak self] in
            self?.window?.close()
            self?.calibrate()
        })))
        tabs.addTabViewItem(item("Keyboard", symbol: "keyboard", KeyboardPane(hotKeys: hotKeys)))
        tabs.addTabViewItem(item("About", symbol: "info.circle", AboutPane()))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.tabs = tabs
        self.window = window
    }

    private func item<Content: View>(_ label: String, symbol: String, _ view: Content) -> NSTabViewItem {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = [.preferredContentSize]
        // The window takes the selected tab's title.
        controller.title = label
        let item = NSTabViewItem(viewController: controller)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        return item
    }
}

// MARK: General

private struct GeneralPane: View {
    @ObservedObject var glow: AmbientGlow
    @ObservedObject var collapsePause: CollapsePause
    @ObservedObject var awayPause: AwayPause
    @ObservedObject var onlookerHide: OnlookerHide
    @ObservedObject var loginItem: LoginItem
    let updates: Updates
    @State private var checksForUpdates = true
    @State private var accessibility = Permissions.accessibility
    @State private var screenRecording = Permissions.screenRecording
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionCard(symbol: "hand.point.up.left.fill", title: "Accessibility",
                               detail: "Finds the Picture in Picture window and presses its buttons.",
                               granted: accessibility, action: Permissions.requestAccessibility, isCard: false)
                PermissionCard(symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                               detail: "Shows the video in the island. macOS applies it after a relaunch.",
                               granted: screenRecording, action: Permissions.requestScreenRecording, isCard: false)
            }
            Section("Startup") {
                Toggle(isOn: Binding(get: { loginItem.isEnabled || loginItem.needsApproval }, set: { loginItem.set($0) })) {
                    Text("Open at login")
                    Text("CineNotch starts with your Mac, so it's there when a video goes into Picture in Picture.")
                }
                if loginItem.needsApproval {
                    HStack {
                        Text("macOS keeps it off until you allow CineNotch in Login Items.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { loginItem.openSystemSettings() }
                    }
                }
            }
            Section("Island") {
                Toggle(isOn: $glow.isEnabled) {
                    Text("Glow under the video")
                    Text("The video's colors softly light up the page under the open island.")
                }
                Toggle(isOn: $collapsePause.isEnabled) {
                    Text("Pause when the island closes")
                    Text("The video plays only while the island is open. A video you paused stays paused.")
                }
                Toggle(isOn: $awayPause.isEnabled) {
                    Text("Pause when you step away")
                    Text("With the glance on, nobody in front of the camera for 3 seconds pauses the video. It plays again when you're back.")
                }
                Toggle(isOn: $onlookerHide.isEnabled) {
                    Text("Hide when someone's behind you")
                    Text("With the glance on, a second face near the camera tucks the island into the notch and pauses the video. Open it again once they're gone.")
                }
            }
            if updates.isAvailable {
                Section("Updates") {
                    Toggle(isOn: Binding(get: { checksForUpdates }, set: { on in
                        checksForUpdates = on
                        updates.automaticallyChecks = on
                    })) {
                        Text("Check for updates automatically")
                        Text("Once a day CineNotch asks cinenotch.cam whether there's a new version. Nothing else is sent.")
                    }
                    Button("Check Now") { updates.checkForUpdates() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { checksForUpdates = updates.automaticallyChecks }
        .onReceive(poll) { _ in
            loginItem.refresh()
            accessibility = Permissions.accessibility
            screenRecording = Permissions.screenRecording
        }
    }
}

// MARK: Keyboard

private struct KeyboardPane: View {
    @ObservedObject var hotKeys: HotKeys

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $hotKeys.isEnabled) {
                    Text("Keyboard shortcuts")
                    Text("They work from any app while a video is docked.")
                }
                if hotKeys.isEnabled {
                    ForEach(HotKeys.Action.allCases, id: \.self) { action in
                        LabeledContent(action.title) {
                            Text(action.shortcut)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Trackpad and mouse") {
                LabeledContent("Move the video") {
                    Text("Scroll over the open video")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Gaze

private extension GazeSensitivity {
    var shortTitle: String {
        switch self {
        case .strict: return "Strict"
        case .balanced: return "Balanced"
        case .sensitive: return "Sensitive"
        }
    }
}

private struct GazePane: View {
    @ObservedObject var gaze: GazeController
    let calibrate: () -> Void

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { gaze.isEnabled }, set: { on in
                    gaze.isEnabled = on
                    if on, !gaze.isCalibrated { calibrate() }
                })) {
                    Text("Reveal the video by glancing at the camera")
                    Text(gaze.isEnabled && !gaze.isCalibrated
                         ? "On, but it needs a 50-second calibration before it can work. Calibrate below."
                         : "The video slides out while you look at it and tucks back in when you look away.")
                }
            }
            Section("Camera") {
                GazePreview(gaze: gaze)
                    .listRowInsets(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            }
            Section {
                Picker("Sensitivity", selection: $gaze.sensitivity) {
                    ForEach(GazeSensitivity.allCases, id: \.self) { Text($0.shortTitle).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Strict opens less often by accident. Sensitive needs fewer repeated glances.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent {
                    Button(gaze.isCalibrated ? "Recalibrate…" : "Calibrate…", action: calibrate)
                } label: {
                    Text("Calibration")
                    Text(gaze.isCalibrated ? "Adjusts to how you sit from your clicks." : "Takes about 50 seconds.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// What the camera sees: the mirrored feed, the eyes it found, and where it thinks you look.
private struct GazePreview: View {
    @ObservedObject var gaze: GazeController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Theme.ink
                if CameraAccess.status == .denied || CameraAccess.status == .restricted {
                    VStack(spacing: 10) {
                        Text("Camera access is off")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        Button("Open Settings") { CameraAccess.openSettings() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    CameraPreview(session: gaze.camera.session)
                    EyeMarkers(features: gaze.features, framesMirrored: gaze.camera.deliversMirroredFrames)
                    StatusChip(text: status, active: gaze.features != nil)
                        .padding(10)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Frames are analyzed on your Mac and never stored or sent anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { gaze.isPreviewVisible = true }
        .onDisappear { gaze.isPreviewVisible = false }
    }

    private var status: String {
        if !gaze.isCameraRunning { return "Starting the camera…" }
        guard gaze.features != nil else { return "Looking for your face" }
        guard gaze.isCalibrated else { return "Face found · calibrate to see where you look" }
        let active = gaze.outputs[gaze.activeEngineID]
        if active?.isBlinking == true { return "Blink" }
        switch active?.zone {
        case .camera: return "Looking at the camera"
        case .video: return "Looking at the video"
        case .work: return "Looking at your work"
        case nil: return "Face found"
        }
    }
}

/// Boxes around the eyes, placed from the head-pose features (eye midpoint, eye distance, roll).
private struct EyeMarkers: View {
    var features: GazeFeatures?
    /// The analyzed frames are already mirrored like the preview.
    var framesMirrored: Bool

    var body: some View {
        GeometryReader { proxy in
            if let head = features?.head, head.count == GazeFeatures.headNames.count {
                let roll = head[2], midX = head[10], midY = head[11], distance = head[12]
                let size = proxy.size
                // Vision coordinates (origin bottom-left) of a 16:9 frame; the preview is a mirror.
                let half = CGVector(dx: cos(roll) * distance / 2, dy: sin(roll) * distance / 2 * 16 / 9)
                let boxWidth = distance * size.width * 0.55
                ForEach([-1.0, 1.0], id: \.self) { side in
                    let x = midX + side * half.dx, y = midY + side * half.dy
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Theme.accent, lineWidth: 1.5)
                        .shadow(color: Theme.accent.opacity(0.6), radius: 3)
                        .frame(width: boxWidth, height: boxWidth * 0.55)
                        .position(x: (framesMirrored ? x : 1 - x) * size.width, y: (1 - y) * size.height)
                }
            }
        }
        .animation(.easeOut(duration: 0.08), value: features?.head.first)
        .allowsHitTesting(false)
    }
}

private struct StatusChip: View {
    var text: String
    var active: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Theme.accent : Color.white.opacity(0.4))
                .frame(width: 6, height: 6)
            Text(text)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }
}

// MARK: About

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Mascot(width: 120)
                .padding(.bottom, 4)
            Text("CineNotch")
                .font(Theme.display(26))
            Text(version)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("Picture in Picture video from Safari or Chrome, tucked into the top of your screen.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 40)
        .frame(width: 480)
    }
}
