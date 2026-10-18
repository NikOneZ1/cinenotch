import AppKit

/// `--debug-demo`: plays a fixed scene on the fake video, the same every time, so recordings
/// of different versions line up. With `--debug-record <file.mov>` the island window is
/// recorded; the app quits at the end.
///
/// The "tour" scene, times from the start of the recording: 0.5 Picture in Picture starts, 2.5
/// hover, 5.0 the cursor leaves, 6.5 a glance that gives up, 8.5 a glance at the camera, 11.5
/// looking away, 12.7 pause, 14.2 play, 15.2 Picture in Picture ends, 16.8 the end.
///
/// The "keys" scene (`--debug-demo-scene keys`): 0.5 Picture in Picture starts, 2.5 ⌃⌥⌘O opens
/// the island, 4.0–4.9 a scroll forward in four steps, 6.6–6.9 a scroll back in two, 8.6 ⌃⌥⌘P
/// pauses, 10.0 ⌃⌥⌘P plays, 11.4 ⌃⌥⌘O closes the island, 13.0 the end.
///
/// The "sizes" scene, from the medium size: 0.3 Picture in Picture starts, 1.2 the island opens,
/// 2.6 a pinch out (large), 4.6 and 6.4 pinches in (medium, small), 8.4 and 10.0 ⌃⌥⌘= (medium,
/// large), 11.8 ⌃⌥⌘− (medium), 13.4 the end.
@MainActor
enum DemoScript {
    static func run(pip: PiPController, island: IslandController, recordTo url: URL?) {
        let scene = LaunchOptions.current.debugDemoScene
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
            if scene == "sizes" {
                await at(0.3) { pip.setFakeActive(true) }
                await at(1.2) { island.forceExpanded = true }
                await at(2.6) { island.stepVideoSize(bigger: true) }
                await at(4.6) { island.stepVideoSize(bigger: false) }
                await at(6.4) { island.stepVideoSize(bigger: false) }
                await at(8.4) { island.stepVideoSize(bigger: true) }
                await at(10.0) { island.stepVideoSize(bigger: true) }
                await at(11.8) { island.stepVideoSize(bigger: false) }
                await at(13.4) {}
                await recorder?.stop()
                if recorder != nil { NSApp.terminate(nil) }
                return
            }
            if scene == "keys" {
                await at(0.5) { pip.setFakeActive(true) }
                await at(2.5) { island.toggleFromKeyboard() }
                for time in [4.0, 4.3, 4.6, 4.9] {
                    await at(time) { island.simulateScroll(steps: 1) }
                }
                await at(6.6) { island.simulateScroll(steps: -1) }
                await at(6.9) { island.simulateScroll(steps: -1) }
                await at(8.6) { pip.togglePlay() }
                await at(10.0) { pip.togglePlay() }
                await at(11.4) { island.toggleFromKeyboard() }
                await at(13.0) {}
                await recorder?.stop()
                if recorder != nil { NSApp.terminate(nil) }
                return
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
