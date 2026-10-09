import AppKit

/// `--debug-demo`: plays a fixed scene on the fake video, the same every time, so recordings
/// of different versions line up. With `--debug-record <file.mov>` the island window is
/// recorded; the app quits at the end.
///
/// Times from the start of the recording: 0.5 Picture in Picture starts, 2.5 hover, 5.0 the
/// cursor leaves, 6.5 a glance that gives up, 8.5 a glance at the camera, 11.5 looking away,
/// 12.7 pause, 14.2 play, 15.2 Picture in Picture ends, 16.8 the end.
@MainActor
enum DemoScript {
    static func run(pip: PiPController, island: IslandController, recordTo url: URL?) {
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let recorder = url.map(WindowRecorder.init(url:))
            if let recorder, let window = island.panelWindowNumber {
                do {
                    try await recorder.start(windowID: CGWindowID(window), size: island.metrics.panelFrame().size, scale: 1.5)
                } catch {
                    Log.info("recording failed: \(error.localizedDescription)")
                }
            }
            let start = Date()
            func at(_ time: Double, _ action: () -> Void) async {
                let wait = time - Date().timeIntervalSince(start)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                action()
            }
            await at(0.5) { pip.setFakeActive(true) }
            await at(2.5) { island.forceExpanded = true }
            await at(5.0) { island.forceExpanded = false }
            await at(6.5) { island.simulateGlance(upTo: 0.6) }
            await at(8.5) { island.simulateGlance(upTo: 1) }
            await at(11.5) { island.simulateLookAway() }
            await at(12.7) { pip.togglePlay() }
            await at(14.2) { pip.togglePlay() }
            await at(15.2) { pip.setFakeActive(false) }
            await at(16.8) {}
            await recorder?.stop()
            if recorder != nil { NSApp.terminate(nil) }
        }
    }
}
