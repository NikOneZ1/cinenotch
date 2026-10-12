import AppKit
import Combine
import SwiftUI

/// The glance is on from the start, but it can't work before a calibration. When a video docks
/// and there's none yet, a small card under the island offers one: calibrate now, later (asked
/// again on the next launch), or turn the glance off and stay with the mouse.
@MainActor
final class GlanceInvite {
    private let gaze: GazeController
    private let island: IslandController
    private let calibrate: () -> Void
    private var panel: NSPanel?
    private var offeredThisLaunch = false
    private var pending: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    init(gaze: GazeController, island: IslandController, pip: PiPController, calibrate: @escaping () -> Void) {
        self.gaze = gaze
        self.island = island
        self.calibrate = calibrate
        pip.$isActive
            .removeDuplicates()
            .sink { [weak self] active in active ? self?.offerSoon() : self?.hide() }
            .store(in: &cancellables)
        gaze.$isCalibrated
            .filter { $0 }
            .sink { [weak self] _ in self?.hide() }
            .store(in: &cancellables)
    }

    /// Worth asking: the glance is on but can't run, and nothing else is in the way.
    private var isNeeded: Bool {
        gaze.isEnabled && gaze.hasLoadedCalibration && !gaze.isCalibrated && !gaze.isCalibrating
            && Onboarding.isDone && CameraAccess.status != .denied && CameraAccess.status != .restricted
    }

    private func offerSoon() {
        guard !offeredThisLaunch, panel == nil else { return }
        pending?.cancel()
        // Let the island grow out of the notch first, then ask.
        pending = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, self.isNeeded else { return }
            self.show()
        }
    }

    func show() {
        offeredThisLaunch = true
        let view = GlanceInviteCard(
            onCalibrate: { [weak self] in
                self?.hide()
                self?.calibrate()
            },
            onLater: { [weak self] in self?.hide() },
            onMouse: { [weak self] in
                self?.gaze.isEnabled = false
                self?.hide()
            })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = host
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        // Centered under the collapsed island, kept on the screen.
        let island = self.island.collapsedRectOnScreen(), screen = self.island.metrics.screenFrame
        let x = min(max(island.midX - size.width / 2, screen.minX + 8), screen.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x.rounded(), y: (island.minY - 14 - size.height).rounded()))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.25; panel.animator().alphaValue = 1 }
        self.panel = panel
        Log.info("glance invite: shown")
    }

    func hide() {
        pending?.cancel()
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 },
                                             completionHandler: { panel.orderOut(nil) })
    }

    /// `--debug-windows`: the card in light and dark, drawn offscreen, so no screen capture permission is needed.
    static func renderPreviews(into dir: URL) {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(content: GlanceInviteCard(onCalibrate: {}, onLater: {}, onMouse: {})
                    .environment(\.colorScheme, name == "dark" ? .dark : .light))
                renderer.scale = 2
                guard let image = renderer.cgImage,
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                try? png.write(to: dir.appendingPathComponent("glance-invite-\(name).png"))
            }
        }
    }
}

private struct GlanceInviteCard: View {
    let onCalibrate: () -> Void
    let onLater: () -> Void
    let onMouse: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Mascot(width: 52)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open it with a glance")
                        .font(Theme.display(16))
                    Text("Look at the camera and the video slides out. First, a 50-second calibration so CineNotch learns your eyes.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Button("Calibrate", action: onCalibrate)
                        .buttonStyle(AccentButtonStyle())
                    Button("Later", action: onLater)
                        .buttonStyle(QuietButtonStyle())
                }
                Button("I'll use the mouse", action: onMouse)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .underline()
            }
        }
        .padding(16)
        .frame(width: 340, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline))
        .padding(1)
    }
}
