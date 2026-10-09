import AppKit

/// Calibration: the user follows a dot across the camera, the video spot and the rest of the
/// screen (sometimes moving the head while looking) while we record gaze features. Every
/// engine version then trains on the same samples.
@MainActor
final class GazeCalibrator {
    private let gaze: GazeController
    private let island: IslandController
    private var overlay: GazeOverlay?
    private var task: Task<Void, Never>?

    private let framesPerStep = 16
    private let framesPerHeadStep = 60
    private let stepTimeout: TimeInterval = 12

    var isRunning: Bool { overlay != nil }

    init(gaze: GazeController, island: IslandController) {
        self.gaze = gaze
        self.island = island
    }

    func start() {
        guard overlay == nil, CameraAccess.ensureAuthorized(then: { [weak self] in self?.start() }) else { return }
        guard let overlay = GazeOverlay(island: island, onCancel: { [weak self] in self?.finish(cancelled: true) }) else { return }
        self.overlay = overlay
        island.ignoresMouse = true
        overlay.model.reset(instruction: "Follow the dot with your eyes")
        gaze.isCalibrating = true
        Log.info("gaze: calibration started")
        task = Task { [weak self] in await self?.run(overlay) }
    }

    private func run(_ overlay: GazeOverlay) async {
        let model = overlay.model
        let frame = overlay.frame
        await overlay.showIntro(title: "Quick calibration", subtitle: "About 50 seconds. Follow the targets with your eyes.", movesHead: true)
        guard !Task.isCancelled else { return }
        let steps = makeSteps(GazeSteps(frame: frame, island: island))
        var samples: [GazeSample] = []
        for (index, step) in steps.enumerated() {
            model.show(step, index: index, of: steps.count, in: frame)
            island.forceExpanded = step.target == .video
            island.videoMarker = step.videoSpot
            island.videoMarkerProgress = 0

            try? await Task.sleep(nanoseconds: UInt64(step.leadIn * 1e9))
            guard !Task.isCancelled else { return }

            let aim = step.normalizedAim(in: frame)
            var collected: [GazeSample] = []
            let started = Date()
            gaze.calibrationSink = { [model] features in
                if let features {
                    collected.append(GazeSample(target: step.target, step: index, x: Double(aim.x), y: Double(aim.y),
                                                openness: features.openness, values: features.vector))
                    model.hint = nil
                } else {
                    model.hint = "Can't see your face. Sit in front of the camera."
                }
            }
            let needed = step.moveHead ? framesPerHeadStep : framesPerStep
            while collected.count < needed, Date().timeIntervalSince(started) < stepTimeout {
                // Nothing new to read while recording: the eyes stay on the target.
                model.progress = Double(collected.count) / Double(needed)
                island.videoMarkerProgress = model.progress
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard !Task.isCancelled else { return }
            }
            model.progress = 1
            model.subInstruction = nil
            gaze.calibrationSink = nil
            samples += collected
        }
        island.forceExpanded = false
        island.videoMarker = nil

        model.stepLabel = ""
        model.message("Learning how you look…", working: true)
        let reports = await gaze.applyCalibration(samples)
        // Each engine's numbers are in the log (GazeController.train).
        Log.info("gaze: calibration finished, \(samples.count) samples")
        if reports.isEmpty {
            model.message("Couldn't see enough of your face", subtitle: "Try again facing the screen, in better light.")
        } else {
            model.message("You're all set",
                          subtitle: "Glance at the camera to bring the video out. It gets steadier as you use your Mac.")
        }
        model.stepLabel = "Click or press Esc to close"
        overlay.closesOnClick = true
    }

    private func makeSteps(_ s: GazeSteps) -> [GazeStep] {
        // Targets interleaved so slow posture drift doesn't line up with one of them. The video
        // gets dots across its area, and the top of the screen gets "elsewhere" traps right
        // next to the camera's direction.
        [
            s.camera, s.dot(0.5, 0.5), s.video, s.dot(0.1, 0.1), s.underPill(0.32), s.moving(s.camera),
            s.dot(0.9, 0.9), s.video(at: CGPoint(x: 0.2, y: 0.25)), s.underPill(0.68), s.dot(0.1, 0.9),
            s.moving(s.video), s.dot(0.9, 0.1), s.dot(0.5, 0.9), s.video(at: CGPoint(x: 0.8, y: 0.75)),
            s.dot(0.1, 0.5), s.dot(0.9, 0.5), s.moving(s.dot(0.5, 0.5)), s.camera, s.moving(s.dot(0.15, 0.8)),
        ]
    }

    private func finish(cancelled: Bool) {
        task?.cancel()
        task = nil
        gaze.calibrationSink = nil
        gaze.isCalibrating = false
        island.forceExpanded = false
        island.videoMarker = nil
        island.ignoresMouse = false
        overlay?.close()
        overlay = nil
        if cancelled { Log.info("gaze: calibration closed") }
    }
}

extension CameraAccess {
    /// True when the camera can be used now; otherwise asks for access (calling `then` once
    /// granted) or sends the user to System Settings.
    @MainActor static func ensureAuthorized(then: @escaping @MainActor () -> Void) -> Bool {
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            request { granted in if granted { then() } }
            return false
        default:
            Log.info("gaze: camera access denied")
            openSettings()
            return false
        }
    }
}
