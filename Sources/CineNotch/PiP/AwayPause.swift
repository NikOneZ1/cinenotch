import Combine
import Foundation

/// "Pause When You Step Away": while the glance has the camera on, nobody in front of it for a few
/// seconds pauses the video, and it plays again when a face is back. Only what this paused plays
/// again: a video the user paused stays paused.
@MainActor
final class AwayPause: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            reset()
            Log.info("pause when you step away: \(isEnabled)")
        }
    }

    private static let enabledKey = "pausesWhenAway"
    /// How long nobody has to be in front of the camera before the video pauses. Looking down at
    /// the keyboard or turning to someone loses the face for a moment too.
    private static let awayAfter: TimeInterval = 3
    /// How long a face has to stay before the video plays again, so a stray detection doesn't.
    private static let backAfter: TimeInterval = 0.4
    private let pip: PiPController
    private let island: IslandController
    private let gaze: GazeController
    /// No face in any frame since then.
    private var absentSince: TimeInterval?
    /// A face in every frame since then.
    private var presentSince: TimeInterval?
    /// This absence was already acted on (or the user played the video during it).
    private var handledAbsence = false
    /// The video was paused because nobody was there, so a face plays it again.
    private var pausedByAway = false
    private var cancellables = Set<AnyCancellable>()

    init(pip: PiPController, island: IslandController, gaze: GazeController) {
        self.pip = pip
        self.island = island
        self.gaze = gaze
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        // The demo plays and pauses on its own cues.
        guard !LaunchOptions.current.debugDemo else { return }
        gaze.$features
            .sink { [weak self] features in self?.frame(hasFace: features != nil) }
            .store(in: &cancellables)
        gaze.$isCameraRunning
            .removeDuplicates()
            .sink { [weak self] running in if !running { self?.reset() } }
            .store(in: &cancellables)
        // Playing again while away means the user resumed it (Safari, media keys).
        pip.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in
                guard let self, playing, pausedByAway else { return }
                pausedByAway = false
                handledAbsence = true
            }
            .store(in: &cancellables)
    }

    private func frame(hasFace: Bool) {
        // Calibration and the gaze test drive the island on their own; the camera may also run
        // for the Settings preview with no video docked.
        guard isEnabled, gaze.isEnabled, gaze.isCameraRunning, !gaze.isCalibrating, !gaze.isTesting,
              island.isVisible, !island.ignoresMouse else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if hasFace {
            absentSince = nil
            handledAbsence = false
            let since = presentSince ?? now
            presentSince = since
            guard pausedByAway, now - since >= Self.backAfter else { return }
            pausedByAway = false
            if pip.play() { Log.info("played: back in front of the camera") }
        } else {
            presentSince = nil
            let since = absentSince ?? now
            absentSince = since
            guard !handledAbsence, now - since >= Self.awayAfter else { return }
            handledAbsence = true
            pausedByAway = pip.pause()
            if pausedByAway { Log.info("paused: nobody in front of the camera") }
        }
    }

    private func reset() {
        absentSince = nil
        presentSince = nil
        handledAbsence = false
        pausedByAway = false
    }
}
