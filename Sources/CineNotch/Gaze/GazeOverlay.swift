import AppKit
import SwiftUI

/// A target the user looks at during calibration or a gaze test.
struct GazeStep {
    var target: GazeTarget
    /// Where the dot is drawn, screen coordinates (bottom-left origin).
    var point: CGPoint
    var instruction: String
    /// Where the instruction goes; nil = next to the dot.
    var labelPoint: CGPoint?
    /// Where the eyes actually go, screen-normalized (y down); nil = the dot itself.
    var aim: CGPoint?
    /// The user keeps looking at the target while moving the head.
    var moveHead = false
    /// For video targets: where the dot sits on the video (0...1, y down).
    var videoSpot: CGPoint?
    /// The user clicks the dot: a gaze anchor, as clicks are in everyday use.
    var click = false

    /// Time to find the target before recording starts; the camera is the farthest away.
    /// Head-movement steps add time to read the instruction, which then stays put.
    var leadIn: TimeInterval {
        let find: TimeInterval
        switch target {
        case .camera: find = 1.3
        case .video: find = 1.0
        case .work: find = 0.75
        }
        return find + (moveHead ? 0.6 : 0)
    }

    func normalizedAim(in frame: CGRect) -> CGPoint {
        aim ?? CGPoint(x: (point.x - frame.minX) / frame.width, y: (frame.maxY - point.y) / frame.height)
    }
}

/// Builds steps for one screen and island layout.
@MainActor
struct GazeSteps {
    let frame: CGRect
    let island: IslandController

    /// The dot sits just below the menu bar and the pill; the eyes go to the lens above the screen.
    var camera: GazeStep {
        GazeStep(target: .camera, point: CGPoint(x: frame.midX, y: frame.maxY - 46),
                 instruction: "Look into the camera lens above the screen",
                 aim: CGPoint(x: 0.5, y: GazeMath.cameraY))
    }

    var video: GazeStep { video(at: CGPoint(x: 0.5, y: 0.5)) }

    /// A dot drawn on the video itself; the island covers the overlay there, so the label goes underneath.
    func video(at spot: CGPoint) -> GazeStep {
        let island = self.island.expandedRectOnScreen()
        return GazeStep(target: .video, point: self.island.videoPointOnScreen(spot),
                        instruction: "Look at the dot on the video",
                        labelPoint: CGPoint(x: island.midX, y: island.minY - 30), videoSpot: spot)
    }

    /// Right under the pill, where browser tabs and address bars sit: the spot most easily
    /// mistaken for a glance at the camera.
    func underPill(_ x: CGFloat) -> GazeStep {
        dot(x, 0.06)
    }

    func dot(_ x: CGFloat, _ fromTop: CGFloat) -> GazeStep {
        GazeStep(target: .work, point: CGPoint(x: frame.minX + frame.width * x, y: frame.maxY - frame.height * fromTop),
                 instruction: "Look at the dot")
    }

    /// A dot right under the expanded island: the closest "elsewhere" gets to the video.
    var belowIsland: GazeStep {
        let rect = island.expandedRectOnScreen()
        return GazeStep(target: .work, point: CGPoint(x: rect.midX, y: rect.minY - 0.08 * frame.height),
                        instruction: "Look at the dot")
    }

    func clicking(_ step: GazeStep) -> GazeStep {
        var step = step
        step.click = true
        step.instruction = "Click the dot"
        return step
    }

    func moving(_ step: GazeStep) -> GazeStep {
        var step = step
        step.moveHead = true
        return step
    }
}

@MainActor
final class GazeOverlayModel: ObservableObject {
    /// Overlay coordinates, top-left origin; nil hides the target.
    @Published var point: CGPoint?
    @Published var labelPoint: CGPoint?
    /// Decides how the target is drawn: a white dot, the video, or an arrow up to the lens.
    @Published var targetKind: GazeTarget = .work
    @Published var instruction = ""
    /// Second line under the instruction, e.g. which way to move the head.
    @Published var subInstruction: String?
    @Published var stepLabel = ""
    /// Fills only while recording; empty while the user is still finding the target.
    @Published var progress = 0.0
    @Published var hint: String?
    /// The legend shown before the first step.
    @Published var showsIntro = false
    @Published var introTitle = ""
    @Published var introSubtitle: String?
    @Published var introMovesHead = false
    /// Position in the run, for the overall progress bar; no bar while `stepCount` is 0.
    @Published var stepIndex = 0
    @Published var stepCount = 0
    /// Second line of a message in the middle of the screen.
    @Published var subtitle: String?
    /// The mascot above a message in the middle of the screen.
    @Published var showsMascot = false
    /// A spinner under the message.
    @Published var isWorking = false
    /// Final lines shown in the middle of the screen (results).
    @Published var lines: [String] = []

    func reset(instruction: String) {
        point = nil
        labelPoint = nil
        targetKind = .work
        self.instruction = instruction
        subInstruction = nil
        stepLabel = ""
        progress = 0
        hint = nil
        showsIntro = false
        stepIndex = 0
        stepCount = 0
        subtitle = nil
        showsMascot = false
        isWorking = false
        lines = []
    }

    /// A message in the middle of the screen, with the mascot.
    func message(_ title: String, subtitle: String? = nil, working: Bool = false) {
        point = nil
        hint = nil
        stepCount = 0
        instruction = title
        self.subtitle = subtitle
        showsMascot = true
        isWorking = working
    }

    func show(_ step: GazeStep, index: Int, of count: Int, in frame: CGRect) {
        showsIntro = false
        stepIndex = index
        stepCount = count
        stepLabel = "Esc to cancel"
        targetKind = step.target
        instruction = step.instruction
        point = CGPoint(x: step.point.x - frame.minX, y: frame.maxY - step.point.y)
        labelPoint = step.labelPoint.map { CGPoint(x: $0.x - frame.minX, y: frame.maxY - $0.y) }
        progress = 0
        subInstruction = step.moveHead ? "Keep your eyes on it and slowly circle your head" : nil
    }
}

/// The dimmed full-screen window both calibration and the gaze test draw on.
@MainActor
final class GazeOverlay {
    let model = GazeOverlayModel()
    let frame: CGRect
    fileprivate let window: GazeOverlayWindow
    private var startContinuation: CheckedContinuation<Void, Never>?

    init?(island: IslandController, onCancel: @escaping () -> Void) {
        let frame = island.metrics.screenFrame
        guard let screen = NSScreen.screens.first(where: { $0.frame == frame }) ?? NSScreen.main else { return nil }
        self.frame = frame
        window = GazeOverlayWindow(screen: screen)
        window.contentView = NSHostingView(rootView: GazeOverlayView(model: model))
        window.onCancel = onCancel
        window.onStart = { [weak self] in self?.resumeStart() }
        window.onClick = { [weak self] in self?.onClick?() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shows the legend and waits for a click or Space.
    func showIntro(title: String, subtitle: String? = nil, movesHead: Bool) async {
        model.introTitle = title
        model.introSubtitle = subtitle
        model.introMovesHead = movesHead
        model.showsIntro = true
        model.stepLabel = "Click or press Space to start · Esc to cancel"
        window.waitsForStart = true
        await withCheckedContinuation { startContinuation = $0 }
        window.waitsForStart = false
        model.showsIntro = false
        model.stepLabel = ""
    }

    /// Called for clicks while a step runs.
    var onClick: (() -> Void)?

    /// Also closes on a click, for result screens.
    var closesOnClick: Bool {
        get { window.closesOnClick }
        set { window.closesOnClick = newValue }
    }

    func close() {
        resumeStart()
        window.orderOut(nil)
        NSApp.deactivate()
    }

    private func resumeStart() {
        startContinuation?.resume()
        startContinuation = nil
    }
}

private final class GazeOverlayWindow: NSWindow {
    var onCancel: (() -> Void)?
    var onStart: (() -> Void)?
    var onClick: (() -> Void)?
    var closesOnClick = false
    var waitsForStart = false

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        // Above the menu bar but below the island, so video steps show the real video.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: onCancel?()
        case 49 where waitsForStart, 36 where waitsForStart: onStart?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func mouseDown(with event: NSEvent) {
        if waitsForStart {
            onStart?()
        } else if closesOnClick {
            onCancel?()
        } else {
            onClick?()
        }
    }
}

private let warningColor = Color(red: 1, green: 0.74, blue: 0.32)

/// Every target is drawn in the one accent; they differ by shape, not color.
private struct GazeOverlayView: View {
    @ObservedObject var model: GazeOverlayModel

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.86)

                if model.showsIntro {
                    IntroLegend(title: model.introTitle, subtitle: model.introSubtitle, movesHead: model.introMovesHead)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                } else if let point = model.point {
                    if model.targetKind == .camera {
                        CameraTarget(progress: model.progress)
                            .position(x: proxy.size.width / 2, y: 0)
                    } else {
                        DotTarget(progress: model.progress)
                            .position(point)
                    }
                    label
                        .position(labelPosition(point: point, in: proxy.size))
                } else {
                    CenterMessage(model: model)
                        .frame(maxWidth: proxy.size.width - 80)
                        .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                }

                footer
                    .position(x: proxy.size.width / 2, y: proxy.size.height - 48)
            }
            .animation(.easeInOut(duration: 0.45), value: model.point)
            .animation(.linear(duration: 0.1), value: model.progress)
        }
        .ignoresSafeArea()
    }

    private var label: some View {
        VStack(spacing: 8) {
            Text(model.instruction)
                .font(Theme.display(model.targetKind == .camera ? 24 : 20, .bold))
                .foregroundStyle(Color.white)
            if let sub = model.subInstruction {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Theme.accent)
                    Text(sub)
                }
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.85))
            }
        }
        .fixedSize()
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if let hint = model.hint {
                Label(hint, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(warningColor)
            }
            if model.stepCount > 0 {
                OverallProgress(value: (Double(model.stepIndex) + model.progress) / Double(model.stepCount))
            }
            Text(model.stepLabel)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.5))
        }
    }

    private func labelPosition(point: CGPoint, in size: CGSize) -> CGPoint {
        if model.targetKind == .camera { return CGPoint(x: size.width / 2, y: 232) }
        return model.labelPoint ?? CGPoint(
            x: min(max(point.x, 220), size.width - 220),
            y: point.y < size.height * 0.6 ? point.y + 62 : point.y - 62)
    }
}

/// How far through the whole run the user is.
private struct OverallProgress: View {
    var value: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.14))
            Capsule().fill(Theme.accent)
                .frame(width: 280 * min(max(value, 0), 1))
        }
        .frame(width: 280, height: 4)
    }
}

/// A dot with a ring that fills while recording.
private struct DotTarget: View {
    var progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(Theme.accent.opacity(0.25), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle().fill(Theme.accent).frame(width: 10, height: 10)
        }
        .frame(width: 34, height: 34)
    }
}

/// No dot to fixate on: a glow under the lens and lines streaming up into it, so the eyes
/// leave the screen.
private struct CameraTarget: View {
    var progress: Double

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                Capsule()
                    .fill(Theme.accent)
                    // Wider than the pill, which sits on top of the overlay right under the lens.
                    .frame(width: 380, height: 10)
                    .blur(radius: 8)
                Beams()
                    .frame(width: 520, height: 150)
            }
            .frame(height: 150, alignment: .top)
            ZStack {
                Circle().stroke(Theme.accent.opacity(0.25), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "camera.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 34, height: 34)
        }
        // Anchored to the top edge: the glow sits right under the lens.
        .frame(height: 300, alignment: .top)
        .offset(y: 150)
    }
}

/// Dashed lines converging on the top center, their dashes flowing up.
private struct Beams: View {
    var count = 9
    var speed: Double = 40

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let apex = CGPoint(x: size.width / 2, y: 0)
                let phase = CGFloat((t * speed).truncatingRemainder(dividingBy: 18))
                for i in 0..<count {
                    let f = CGFloat(i) / CGFloat(count - 1) - 0.5
                    let start = CGPoint(x: size.width / 2 + f * size.width * 0.8, y: size.height)
                    var path = Path()
                    path.move(to: start)
                    path.addLine(to: apex)
                    canvas.stroke(path,
                                  with: .linearGradient(Gradient(colors: [Theme.accent.opacity(0), Theme.accent.opacity(0.9)]),
                                                        startPoint: start, endPoint: apex),
                                  style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 12], dashPhase: phase))
                }
            }
        }
    }
}

/// Calculating, done, failed: a message with the mascot, or test results.
private struct CenterMessage: View {
    @ObservedObject var model: GazeOverlayModel

    var body: some View {
        VStack(spacing: 16) {
            if model.showsMascot {
                Mascot(width: 110)
                    .padding(.bottom, 6)
            }
            Text(model.instruction)
                .font(Theme.display(28))
                .multilineTextAlignment(.center)
            if let subtitle = model.subtitle {
                Text(subtitle)
                    .font(.system(size: 16))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            if model.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .colorScheme(.dark)
            }
            ForEach(model.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.9))
            }
        }
        .foregroundStyle(Color.white)
    }
}

private struct IntroLegend: View {
    var title: String
    var subtitle: String?
    var movesHead: Bool

    var body: some View {
        VStack(spacing: 24) {
            Mascot(width: 84)
            VStack(spacing: 6) {
                Text(title)
                    .font(Theme.display(28))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.white.opacity(0.7))
                }
            }
            HStack(alignment: .top, spacing: 14) {
                card(title: "Dots", text: "On the screen or on the video. Look at the dot until its ring fills.") {
                    ZStack {
                        Circle().stroke(Theme.accent.opacity(0.3), lineWidth: 3)
                        Circle().trim(from: 0, to: 0.65)
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Circle().fill(Theme.accent).frame(width: 9, height: 9)
                    }
                    .frame(width: 30, height: 30)
                }
                card(title: "The camera", text: "Lines lead up to the lens. Look into the lens above the screen, not at the lines.") {
                    ZStack(alignment: .top) {
                        Capsule().fill(Theme.accent).frame(width: 40, height: 4).blur(radius: 3)
                        Beams(count: 5, speed: 20).frame(width: 48, height: 30)
                    }
                    .frame(width: 48, height: 32)
                }
                if movesHead {
                    card(title: "Circle your head", text: "When asked, keep your eyes on the target and slowly circle your head.") {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
            // Cards as tall as the tallest one.
            .fixedSize(horizontal: false, vertical: true)
            Text("Each target shows up first, then its ring fills while it records. Keep your eyes on it until the ring is full.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.white)
        .padding(36)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(white: 0.06))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(Color.white.opacity(0.08)))
        )
    }

    private func card<Icon: View>(title: String, text: String, @ViewBuilder icon: () -> Icon) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            icon()
                .frame(height: 36, alignment: .leading)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 190, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.white.opacity(0.06)))
    }
}

extension GazeOverlay {
    /// Developer flag `--debug-overlay <dir>`: shows the intro, one target of each kind and the
    /// finish screen, saving a picture of the overlay window (alone) for each, then closes.
    static func preview(island: IslandController, into dir: URL) async {
        guard let overlay = GazeOverlay(island: island, onCancel: {}) else { return }
        let frame = overlay.frame
        let s = GazeSteps(frame: frame, island: island)
        func snap(_ name: String) async {
            try? await Task.sleep(nanoseconds: 900_000_000)
            DebugSnapshot.captureWindow(CGWindowID(overlay.window.windowNumber), to: dir.appendingPathComponent("\(name).png"))
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        overlay.model.introTitle = "Quick calibration"
        overlay.model.introSubtitle = "About 50 seconds. Follow the targets with your eyes."
        overlay.model.introMovesHead = true
        overlay.model.showsIntro = true
        overlay.model.stepLabel = "Click or press Space to start · Esc to cancel"
        await snap("intro")
        for (name, step) in [("camera", s.camera), ("video", s.video), ("dot", s.moving(s.dot(0.2, 0.7)))] {
            overlay.model.show(step, index: 7, of: 19, in: frame)
            island.forceExpanded = step.target == .video
            overlay.model.progress = 0.6
            await snap(name)
        }
        island.forceExpanded = false
        overlay.model.stepLabel = "Click or press Esc to close"
        overlay.model.message("You're all set",
                              subtitle: "Glance at the camera to bring the video out. It gets steadier as you use your Mac.")
        await snap("done")
        overlay.close()
    }
}
