import Combine
import Foundation

/// "Hide When Someone's Behind You": while the glance has the camera on, a second face near it
/// tucks the island into the notch and pauses the video. When only the user is left, the island
/// comes back, and the video plays again once the island opens. Only what this paused plays again.
/// Someone who stays for a minute is watching along (or is a face on a poster): the island comes
/// back and stays until they've left.
@MainActor
final class OnlookerHide: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            reset()
            Log.info("hide when someone's behind you: \(isEnabled)")
        }
    }

    private static let enabledKey = "hidesForOnlookers"
    /// Face detection runs a few times a second; a second face this long is someone, not a glitch.
    private static let seenFor: TimeInterval = 0.5
    /// How long only the user has to be in front of the camera before the island comes back.
    private static let goneFor: TimeInterval = 3
    /// The face that's left counts as the user's when it's at least this big next to theirs:
    /// if the user turns away, the onlooker alone must not bring the island back.
    private static let userFaceRatio: CGFloat = 0.75
    /// The longest the island stays hidden for one onlooker.
    private static let longestHide: TimeInterval = 60
    private let pip: PiPController
    private let island: IslandController
    private let gaze: GazeController
    /// Two or more faces in every detection since then.
    private var seenSince: TimeInterval?
    /// Only the user in every detection since then.
    private var goneSince: TimeInterval?
    /// The user's face width when the island hid.
    private var userFace: CGFloat = 0
    private var hiddenAt: TimeInterval = 0
    /// The other face stayed past `longestHide`: no hiding again until they've left.
    private var isWatchedTogether = false
    /// The video was paused because someone showed up, so the next open plays it again.
    private var pausedByOnlooker = false
    private var cancellables = Set<AnyCancellable>()

    init(pip: PiPController, island: IslandController, gaze: GazeController) {
        self.pip = pip
        self.island = island
        self.gaze = gaze
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        // The demo plays and pauses on its own cues.
        guard !LaunchOptions.current.debugDemo else { return }
        // Every analyzed frame, with the faces already updated.
        gaze.$features
            .sink { [weak self] _ in self?.frame() }
            .store(in: &cancellables)
        gaze.$isCameraRunning
            .removeDuplicates()
            .sink { [weak self] running in if !running { self?.reset() } }
            .store(in: &cancellables)
        island.$isExpanded
            .removeDuplicates()
            .sink { [weak self] expanded in
                guard let self, expanded, pausedByOnlooker else { return }
                pausedByOnlooker = false
                if pip.play() { Log.info("played on expand after hiding") }
            }
            .store(in: &cancellables)
        // Playing again while hidden means the user resumed it (Safari, media keys).
        pip.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in if playing { self?.pausedByOnlooker = false } }
            .store(in: &cancellables)
    }

    private func frame() {
        // Calibration and the gaze test drive the island on their own; the camera may also run
        // for the Settings preview with no video docked.
        guard isEnabled, gaze.isEnabled, gaze.isCameraRunning, !gaze.isCalibrating, !gaze.isTesting,
              pip.isActive, !island.ignoresMouse else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let faces = gaze.nearbyFaces
        if isWatchedTogether {
            guard faces.count <= 1 else {
                goneSince = nil
                return
            }
            let since = goneSince ?? now
            goneSince = since
            guard now - since >= Self.goneFor else { return }
            goneSince = nil
            isWatchedTogether = false
            Log.info("only the user again: hiding is back on")
        } else if !island.isTuckedAway {
            guard faces.count >= 2 else {
                seenSince = nil
                return
            }
            let since = seenSince ?? now
            seenSince = since
            guard now - since >= Self.seenFor else { return }
            seenSince = nil
            userFace = faces[0]
            hiddenAt = now
            island.isTuckedAway = true
            pausedByOnlooker = pip.pause()
            Log.info("hid: someone behind the user" + (pausedByOnlooker ? ", paused" : ""))
        } else if now - hiddenAt >= Self.longestHide {
            goneSince = nil
            isWatchedTogether = true
            island.isTuckedAway = false
            Log.info("back: the other face stayed, so they're watching too")
        } else {
            guard faces.count == 1, faces[0] >= userFace * Self.userFaceRatio else {
                goneSince = nil
                return
            }
            let since = goneSince ?? now
            goneSince = since
            guard now - since >= Self.goneFor else { return }
            goneSince = nil
            island.isTuckedAway = false
            Log.info("back: only the user in front of the camera")
        }
    }

    private func reset() {
        seenSince = nil
        goneSince = nil
        pausedByOnlooker = false
        isWatchedTogether = false
        island.isTuckedAway = false
    }
}
