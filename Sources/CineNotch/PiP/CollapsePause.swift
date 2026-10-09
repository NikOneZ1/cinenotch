import Combine
import Foundation

/// "Pause When the Island Closes": the video plays only while the island is open. It pauses
/// when the island collapses (the cursor or the gaze moved on) and plays again when it opens.
/// Only what a collapse paused plays again: a video the user paused stays paused.
@MainActor
final class CollapsePause: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            pausedByCollapse = false
            Log.info("pause when the island closes: \(isEnabled)")
        }
    }

    private static let enabledKey = "pausesWhenCollapsed"
    private let pip: PiPController
    private let island: IslandController
    /// The last collapse paused the video, so the next expand plays it again.
    private var pausedByCollapse = false
    private var cancellables = Set<AnyCancellable>()

    init(pip: PiPController, island: IslandController) {
        self.pip = pip
        self.island = island
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        // The demo plays and pauses on its own cues.
        guard !LaunchOptions.current.debugDemo else { return }
        island.$isExpanded
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] expanded in self?.islandChanged(expanded: expanded) }
            .store(in: &cancellables)
        // Playing again while collapsed means the user resumed it (Safari, media keys).
        pip.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in
                if playing, self?.island.isExpanded == false { self?.pausedByCollapse = false }
            }
            .store(in: &cancellables)
    }

    private func islandChanged(expanded: Bool) {
        // A video that just went away needs nothing; calibration and the gaze test open and
        // close the island on their own.
        guard isEnabled, island.isVisible, !island.ignoresMouse else { return }
        if expanded {
            guard pausedByCollapse else { return }
            pausedByCollapse = false
            if pip.play() { Log.info("played on expand") }
        } else {
            pausedByCollapse = pip.pause()
            if pausedByCollapse { Log.info("paused on collapse") }
        }
    }
}
