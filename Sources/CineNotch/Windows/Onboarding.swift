import AppKit
import Combine
import SwiftUI

/// First run: what CineNotch does, its two permissions, how to start a video.
@MainActor
final class Onboarding: NSObject, NSWindowDelegate {
    enum Step: Int, CaseIterable {
        case welcome, permissions, ready
    }

    /// Both permissions are in (the engine can start).
    var onPermissionsGranted: () -> Void = {}
    /// "Set up" on the last step: calibrate gaze.
    var onSetUpGlance: () -> Void = {}

    static var isDone: Bool { UserDefaults.standard.bool(forKey: doneKey) }
    /// Where to pick up after the relaunch that Screen Recording needs.
    static var resumeStep: Step? {
        (UserDefaults.standard.object(forKey: resumeKey) as? Int).flatMap(Step.init(rawValue:))
    }

    private static let doneKey = "onboardingDone"
    private static let resumeKey = "onboardingResume"
    private let model = OnboardingModel()
    private var window: NSWindow?

    override init() {
        super.init()
        model.onPermissionsGranted = { [weak self] in self?.onPermissionsGranted() }
        model.onRelaunch = {
            UserDefaults.standard.set(Step.permissions.rawValue, forKey: Self.resumeKey)
            Permissions.relaunch()
        }
        model.onDone = { [weak self] setUpGlance in
            UserDefaults.standard.set(true, forKey: Self.doneKey)
            self?.window?.close()
            if setUpGlance { self?.onSetUpGlance() }
        }
    }

    func show(_ step: Step) {
        UserDefaults.standard.removeObject(forKey: Self.resumeKey)
        model.step = step
        model.startPolling()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Welcome to CineNotch"
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: OnboardingView(model: model))
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopPolling()
    }

    func close() { window?.close() }

    var windowNumber: Int? { window?.windowNumber }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step = Onboarding.Step.welcome
    @Published private(set) var accessibility = Permissions.accessibility
    @Published private(set) var screenRecording = Permissions.screenRecording
    var onPermissionsGranted: () -> Void = {}
    var onRelaunch: () -> Void = {}
    var onDone: (_ setUpGlance: Bool) -> Void = { _ in }

    var allGranted: Bool { accessibility && screenRecording }
    private var reported = false
    private var timer: AnyCancellable?

    /// Permissions change in System Settings; check every second while the window is open.
    func startPolling() {
        refresh()
        guard timer == nil else { return }
        timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func stopPolling() {
        timer = nil
    }

    private func refresh() {
        let a = Permissions.accessibility, s = Permissions.screenRecording
        if a != accessibility { accessibility = a }
        if s != screenRecording { screenRecording = s }
        if allGranted, !reported {
            reported = true
            onPermissionsGranted()
        }
    }

    func go(_ step: Onboarding.Step) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { self.step = step }
    }
}

private let hasNotch = NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }

private struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch model.step {
                case .welcome: WelcomeStep(model: model).transition(slide)
                case .permissions: PermissionsStep(model: model).transition(slide)
                case .ready: ReadyStep(model: model).transition(slide)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            PageDots(current: model.step.rawValue, count: Onboarding.Step.allCases.count)
                .padding(.bottom, 22)
        }
        .padding(.horizontal, 40)
        .padding(.top, 36)
        .frame(width: 560, height: 540)
        .background(Theme.paper.ignoresSafeArea())
    }

    private var slide: AnyTransition {
        .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity))
    }
}

private struct PageDots: View {
    var current: Int
    var count: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Color.primary : Color.secondary.opacity(0.3))
                    .frame(width: i == current ? 18 : 6, height: 6)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: current)
    }
}

// MARK: Steps

private struct WelcomeStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 26) {
            IslandDemo()
            VStack(spacing: 10) {
                Text(hasNotch ? "Your video, tucked into the notch" : "Your video, tucked into the menu bar")
                    .font(Theme.display(28))
                    .multilineTextAlignment(.center)
                Text("CineNotch moves Safari's Picture in Picture video into a little island at the top of your screen. Hover it, or just glance at the camera, and the video slides out.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Get started") { model.go(model.allGranted ? .ready : .permissions) }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.bottom, 18)
    }
}

private struct PermissionsStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            VStack(spacing: 10) {
                Text("Two permissions")
                    .font(Theme.display(28))
                Text("CineNotch needs these to move the video out of the way. Everything stays on your Mac.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 12) {
                PermissionCard(symbol: "hand.point.up.left.fill", title: "Accessibility",
                               detail: "Finds the Picture in Picture window, tucks it away and presses its buttons.",
                               granted: model.accessibility, action: Permissions.requestAccessibility)
                PermissionCard(symbol: "rectangle.dashed.badge.record", title: "Screen Recording",
                               detail: "Shows the video in the island. Only the Picture in Picture window is captured.",
                               granted: model.screenRecording, action: Permissions.requestScreenRecording)
            }
            if !model.screenRecording {
                HStack(spacing: 10) {
                    Text("Allowed Screen Recording? macOS applies it after CineNotch restarts.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("Relaunch") { model.onRelaunch() }
                        .buttonStyle(QuietButtonStyle())
                }
            }
            Spacer(minLength: 0)
            if model.allGranted {
                Button("Continue") { model.go(.ready) }
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.bottom, 18)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: model.allGranted)
    }
}

private struct ReadyStep: View {
    @ObservedObject var model: OnboardingModel

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.4), Color(red: 0.42, green: 0.25, blue: 0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 128, height: 72)
                    Image(systemName: "pip.enter")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(Circle().fill(Color.black.opacity(0.35)))
                }
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.secondary)
                Mascot(width: 96)
            }
            VStack(spacing: 10) {
                Text("You're ready")
                    .font(Theme.display(28))
                Text("Start Picture in Picture on any video in Safari. CineNotch picks it up and tucks it \(hasNotch ? "into the notch" : "into the menu bar").")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Image(systemName: "eye")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reveal it with a glance")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Look at the camera and the video slides out. Takes a 50-second calibration.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Set up") { model.onDone(true) }
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
            Spacer(minLength: 0)
            Button("Done") { model.onDone(false) }
                .buttonStyle(AccentButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.bottom, 18)
    }
}

// MARK: Pieces

/// One permission: what it's for, and either a check mark or the way to System Settings.
struct PermissionCard: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void
    /// Draws its own card; off inside a grouped Form, which already draws one.
    var isCard = true

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.green)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Button("Open Settings", action: action)
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(isCard ? 14 : 2)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(isCard ? Theme.card : .clear))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(isCard ? Theme.hairline : .clear))
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: granted)
    }
}

/// A looping sketch of the app: the island in a tiny screen opens on hover, then on a glance.
private struct IslandDemo: View {
    private struct Phase {
        var expanded = false
        /// Cursor position in the screen, nil = hidden.
        var cursor: CGPoint?
        var bump: CGFloat = 0
        var eyes: Double = 0
    }

    private static let phases: [Phase] = [
        Phase(cursor: CGPoint(x: 300, y: 170)),
        Phase(cursor: CGPoint(x: 215, y: 12)),
        Phase(expanded: true, cursor: CGPoint(x: 215, y: 12)),
        Phase(expanded: true, cursor: CGPoint(x: 230, y: 90)),
        Phase(cursor: CGPoint(x: 340, y: 190)),
        Phase(),
        Phase(bump: 10, eyes: 1),
        Phase(expanded: true),
        Phase(expanded: true),
        Phase(),
    ]

    @State private var index = 0
    private let timer = Timer.publish(every: 0.9, on: .main, in: .common).autoconnect()

    var body: some View {
        let phase = Self.phases[index]
        let size = phase.expanded ? CGSize(width: 220, height: 138) : CGSize(width: 168, height: 16)
        ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.97, green: 0.79, blue: 0.75), Color(red: 0.84, green: 0.78, blue: 0.93),
                                    Color(red: 0.72, green: 0.8, blue: 0.95)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // Menu bar and a window behind.
            Rectangle().fill(Color.white.opacity(0.45)).frame(height: 16)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.85))
                .frame(width: 330, height: 170)
                .offset(y: 32)

            IslandShape(topRadius: 0, bottomRadius: phase.expanded ? 16 : 7, bump: phase.bump, bumpWidth: 60)
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) {
                    if phase.expanded {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.4), Color(red: 0.42, green: 0.25, blue: 0.55)],
                                                 startPoint: .top, endPoint: .bottom))
                            .frame(width: 200, height: 112)
                            .padding(.top, 18)
                            .transition(.opacity.combined(with: .scale(scale: 0.4, anchor: .topTrailing)))
                    } else {
                        HStack {
                            Capsule().fill(Color.white.opacity(0.75)).frame(width: 38, height: 3)
                            Spacer()
                            RoundedRectangle(cornerRadius: 2).fill(Color.orange.opacity(0.9)).frame(width: 18, height: 10)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 16)
                        .transition(.opacity)
                    }
                }
                .overlay(alignment: .bottom) {
                    MascotEyes(openness: phase.eyes, eyeSize: CGSize(width: 4, height: 6), spacing: 7)
                        .offset(y: phase.bump / 2)
                        .opacity(phase.eyes)
                }

            if let cursor = phase.cursor {
                Image(systemName: "cursorarrow")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.black)
                    .shadow(color: .white, radius: 0.5)
                    .position(cursor)
                    .transition(.opacity)
            }
        }
        .frame(width: 430, height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline))
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: index)
        .onReceive(timer) { _ in index = (index + 1) % Self.phases.count }
        .accessibilityLabel("The island at the top of the screen opens when you hover it or glance at the camera")
    }
}
