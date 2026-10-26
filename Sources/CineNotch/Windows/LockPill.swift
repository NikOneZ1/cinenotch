import AppKit
import CineNotchLicense
import Combine
import SwiftUI

/// While licensing is on and this Mac isn't activated, a Picture in Picture video can't be docked. This says so, politely:
/// a small pill under the top edge, shown only while there's a video it could have been, with "Buy" and "Enter Key".
/// "Not now" hides it until the next video. It never exists with licensing off.
@MainActor
final class LockPill {
    private var panel: NSPanel?
    private var dismissed = false
    private var cancellables = Set<AnyCancellable>()
    private let license: LicenseManager
    private let enterKey: () -> Void
    private let buy: () -> Void

    init(license: LicenseManager, pip: PiPController, enterKey: @escaping () -> Void, buy: @escaping () -> Void) {
        self.license = license
        self.enterKey = enterKey
        self.buy = buy
        license.$state
            .combineLatest(pip.$lockedVideoPresent)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state, present in
                guard let self else { return }
                if !present { dismissed = false }
                setVisible(!state.isUnlocked && present && !dismissed)
            }
            .store(in: &cancellables)
    }

    private func setVisible(_ visible: Bool) {
        guard visible else {
            panel?.orderOut(nil)
            return
        }
        if panel == nil { makePanel() }
        position()
        panel?.orderFrontRegardless()
    }

    private func makePanel() {
        let view = LockPillView(
            enterKey: { [weak self] in self?.enterKey() },
            buy: { [weak self] in self?.buy() },
            dismiss: { [weak self] in
                self?.dismissed = true
                self?.panel?.orderOut(nil)
            })
        let host = IslandHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let panel = NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        self.panel = panel
    }

    /// Top center of the main screen, just under the menu bar (and the notch).
    private func position() {
        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let top = screen.visibleFrame.maxY - 10
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height, width: size.width, height: size.height),
                       display: true)
    }
}

private struct LockPillView: View {
    let enterKey: () -> Void
    let buy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Mascot(width: 30, awake: false)
                .frame(width: 40, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("Activate CineNotch to dock this video")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Until then it stays a normal floating window.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Button("Enter Key", action: enterKey)
                .buttonStyle(AccentButtonStyle())
                .controlSize(.small)
            Button("Buy", action: buy)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help("Not now")
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .background(Capsule().fill(Theme.ink))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .fixedSize()
    }
}
