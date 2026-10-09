import AppKit
import Foundation

/// A recorded gaze test: every analyzed frame with where the user was told to look.
/// Saved so later engine versions can be scored on exactly the same frames.
struct GazeTestSession: Codable {
    var version: Int
    var date: Date
    /// The expanded island at recording time, screen-normalized.
    var islandRect: CGRect
    var frames: [GazeTestFrame]
    /// Clicks during the test; nil in recordings made before click steps existed.
    var anchors: [GazeAnchor]?

    /// Recorded clicks, or for older recordings, stand-ins: the middle of each of the first two
    /// "elsewhere" steps, as if the user had clicked those dots.
    var effectiveAnchors: [GazeAnchor] {
        if let anchors { return anchors }
        var result: [GazeAnchor] = []
        var seen = Set<Int>()
        for frame in frames where frame.target == .work && frame.settled == true && frame.stepTime >= 1.2 && !seen.contains(frame.step) {
            seen.insert(frame.step)
            result.append(GazeAnchor(time: frame.time, x: frame.x, y: frame.y))
            if result.count == 2 { break }
        }
        return result
    }
}

struct GazeTestFrame: Codable {
    var step: Int
    var target: GazeTarget
    var x: Double
    var y: Double
    /// Since the test started.
    var time: TimeInterval
    /// Since this step's target appeared.
    var stepTime: TimeInterval
    /// The step's lead-in is over: the user has had time to find the target.
    /// Missing in recordings made before lead-ins existed.
    var settled: Bool?
    var openness: Double?
    /// `GazeFeatures.vector`; nil when no face was found.
    var values: [Float]?

    var features: GazeFeatures? {
        guard let values, let openness else { return nil }
        let pixelCount = values.count - GazeFeatures.headNames.count
        return GazeFeatures(pixels: Array(values[..<pixelCount]), head: values[pixelCount...].map(Double.init),
                            openness: openness)
    }
}

/// How one engine did on a recorded test.
struct GazeEvaluation: Codable {
    var engine: String
    /// Share of frames (after the step's lead-in) in the right zone, per target.
    var accuracy: [String: Double]
    /// Camera steps that started collapsed, and how many of them revealed.
    var revealChances = 0
    var reveals = 0
    var revealLatency: Double?
    /// Elsewhere steps that started expanded, and how many of them collapsed.
    var collapseChances = 0
    var collapses = 0
    var collapseLatency: Double?
    /// Reveals while the user was looking somewhere other than the camera.
    var falseReveals = 0
    /// Where each false reveal happened: step and target position.
    var falseRevealSpots: [String] = []
    /// Share of video-step frames during which the video stayed open.
    var videoHold: Double?

    var summary: String {
        func percent(_ value: Double?) -> String { value.map { "\(Int(($0 * 100).rounded()))%" } ?? "–" }
        func seconds(_ value: Double?) -> String { value.map { String(format: "%.2fs", $0) } ?? "–" }
        return "\(engine): zones camera \(percent(accuracy["camera"])) video \(percent(accuracy["video"])) "
            + "elsewhere \(percent(accuracy["work"])) | reveal \(reveals)/\(revealChances) \(seconds(revealLatency)) "
            + "| collapse \(collapses)/\(collapseChances) \(seconds(collapseLatency)) | false reveals \(falseReveals) "
            + "| video held \(percent(videoHold))"
            + (falseRevealSpots.isEmpty ? "" : " | false at " + falseRevealSpots.joined(separator: ", "))
    }

    /// `cameraBoundary` plays the sensitivity setting (v8+); `label` names the result.
    /// `trace` sees every frame with the engine's output, for offline analysis.
    static func run(_ engine: any GazeEngine, on session: GazeTestSession, cameraBoundary: Double? = nil,
                    label: String? = nil, trace: ((GazeTestFrame, GazeOutput) -> Void)? = nil) -> GazeEvaluation {
        let tracker = engine.makeTracker()
        let anchors = session.effectiveAnchors
        var context = GazeContext(islandRect: session.islandRect, cameraBoundary: cameraBoundary)
        var result = GazeEvaluation(engine: label ?? type(of: engine).id, accuracy: [:])
        var hits: [GazeTarget: Int] = [:], counted: [GazeTarget: Int] = [:]
        var revealTimes: [Double] = [], collapseTimes: [Double] = []
        var videoFrames = 0, videoOpen = 0
        var step = -1
        var expandedAtStart = false
        var resolved = false
        var wasExpanded = false

        for frame in session.frames {
            context.anchors = anchors.filter { $0.time <= frame.time }
            let output = tracker.process(frame.features, at: frame.time, context: context)
            trace?(frame, output)
            if frame.step != step {
                step = frame.step
                expandedAtStart = wasExpanded
                resolved = false
                if frame.target == .camera, !expandedAtStart { result.revealChances += 1 }
                if frame.target == .work, expandedAtStart { result.collapseChances += 1 }
            }
            if frame.settled ?? (frame.stepTime >= 0.6), frame.values != nil, let zone = output.zone {
                counted[frame.target, default: 0] += 1
                if zone.rawValue == frame.target.rawValue { hits[frame.target, default: 0] += 1 }
            }
            switch frame.target {
            case .camera:
                if !expandedAtStart, !resolved, output.wantsExpanded {
                    result.reveals += 1
                    revealTimes.append(frame.stepTime)
                    resolved = true
                }
            case .work:
                if expandedAtStart, !resolved, !output.wantsExpanded {
                    result.collapses += 1
                    collapseTimes.append(frame.stepTime)
                    resolved = true
                }
            case .video:
                if frame.stepTime >= 0.3 {
                    videoFrames += 1
                    if output.wantsExpanded { videoOpen += 1 }
                }
            }
            if frame.target != .camera, frame.stepTime >= 0.4, !wasExpanded, output.wantsExpanded {
                result.falseReveals += 1
                result.falseRevealSpots.append(String(format: "step %d %@ (%.2f, %.2f)", frame.step, frame.target.rawValue, frame.x, frame.y))
            }
            wasExpanded = output.wantsExpanded
        }
        for target in GazeTarget.allCases where (counted[target] ?? 0) > 0 {
            result.accuracy[target.rawValue] = Double(hits[target] ?? 0) / Double(counted[target]!)
        }
        result.revealLatency = revealTimes.isEmpty ? nil : revealTimes.reduce(0, +) / Double(revealTimes.count)
        result.collapseLatency = collapseTimes.isEmpty ? nil : collapseTimes.reduce(0, +) / Double(collapseTimes.count)
        result.videoHold = videoFrames > 0 ? Double(videoOpen) / Double(videoFrames) : nil
        return result
    }
}

enum GazeTestStore {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CineNotch/gaze-tests", isDirectory: true)
    }

    static func save(_ session: GazeTestSession) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let name = "test-\(Int(session.date.timeIntervalSince1970)).json"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(session).write(to: directory.appendingPathComponent(name))
        } catch {
            Log.info("gaze: failed to save test: \(error.localizedDescription)")
        }
    }

    /// All recorded tests made with the current feature layout, oldest first.
    static func loadAll() -> [(name: String, session: GazeTestSession)] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let session = try? decoder.decode(GazeTestSession.self, from: data),
                      session.version == GazeFeatures.version else { return nil }
                return (url.lastPathComponent, session)
            }
    }
}

/// The gaze test: ~30 s of following a dot through camera → video → elsewhere sequences,
/// including the usual traps (browser tabs at the top, the spot right under the island).
/// Every engine is scored on the recording.
@MainActor
final class GazeTester {
    private let gaze: GazeController
    private let island: IslandController
    private var overlay: GazeOverlay?
    private var task: Task<Void, Never>?
    /// Recording time per step, after the step's lead-in.
    private let recordDuration: TimeInterval = 1.4

    init(gaze: GazeController, island: IslandController) {
        self.gaze = gaze
        self.island = island
    }

    func start() {
        guard overlay == nil, CameraAccess.ensureAuthorized(then: { [weak self] in self?.start() }) else { return }
        guard let overlay = GazeOverlay(island: island, onCancel: { [weak self] in self?.finish() }) else { return }
        self.overlay = overlay
        guard gaze.isCalibrated else {
            overlay.model.reset(instruction: "Calibrate gaze first")
            overlay.model.stepLabel = "Click or press Esc to close"
            overlay.closesOnClick = true
            return
        }
        island.ignoresMouse = true
        overlay.model.reset(instruction: "Gaze test: follow the dot with your eyes")
        gaze.isTesting = true
        Log.info("gaze: test started")
        task = Task { [weak self] in await self?.run(overlay) }
    }

    private func run(_ overlay: GazeOverlay) async {
        let model = overlay.model
        let frame = overlay.frame
        let s = GazeSteps(frame: frame, island: island)
        // Two clicks first: the anchors v7 corrects posture drift with, as clicks do in everyday use.
        let steps = [
            s.clicking(s.dot(0.25, 0.7)), s.clicking(s.dot(0.75, 0.55)),
            s.dot(0.5, 0.5), s.camera, s.video, s.dot(0.2, 0.8), s.dot(0.08, 0.06), s.camera,
            s.video(at: CGPoint(x: 0.25, y: 0.3)), s.dot(0.92, 0.06), s.dot(0.5, 0.75), s.underPill(0.5), s.camera,
            s.video(at: CGPoint(x: 0.75, y: 0.7)), s.belowIsland, s.dot(0.85, 0.5), s.dot(0.3, 0.25),
        ]
        await overlay.showIntro(title: "Gaze test", movesHead: false)
        guard !Task.isCancelled else { return }

        let clock = { ProcessInfo.processInfo.systemUptime }
        let start = clock()
        var frames: [GazeTestFrame] = []
        var current = 0
        var stepStart = start
        var settled = false
        var anchors: [GazeAnchor] = []
        var clicked = false
        overlay.onClick = {
            guard steps[current].click, !clicked else { return }
            let mouse = NSEvent.mouseLocation
            anchors.append(GazeAnchor(time: clock() - start, x: (mouse.x - frame.minX) / frame.width,
                                      y: (frame.maxY - mouse.y) / frame.height))
            clicked = true
        }
        gaze.testSink = { [model] features in
            let now = clock()
            let step = steps[current]
            let aim = step.normalizedAim(in: frame)
            frames.append(GazeTestFrame(step: current, target: step.target, x: Double(aim.x), y: Double(aim.y),
                                        time: now - start, stepTime: now - stepStart, settled: settled,
                                        openness: features?.openness, values: features?.vector.map(Float.init)))
            model.hint = features == nil ? "Can't see your face" : nil
        }
        for (index, step) in steps.enumerated() {
            current = index
            stepStart = clock()
            settled = false
            model.show(step, index: index, of: steps.count, in: frame)
            island.forceExpanded = step.target == .video
            island.videoMarker = step.videoSpot
            island.videoMarkerProgress = 0
            clicked = false
            if step.click {
                // Wait for the click (or give up after a while), then a moment more.
                while !clicked, clock() - stepStart < 8 {
                    settled = clock() - stepStart >= step.leadIn
                    try? await Task.sleep(nanoseconds: 40_000_000)
                    guard !Task.isCancelled else { return }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
                continue
            }
            // Frames keep coming during the lead-in: reveal timing counts from the target's appearance.
            while clock() - stepStart < step.leadIn + recordDuration {
                let elapsed = clock() - stepStart
                settled = elapsed >= step.leadIn
                model.progress = settled ? (elapsed - step.leadIn) / recordDuration : 0
                island.videoMarkerProgress = model.progress
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard !Task.isCancelled else { return }
            }
        }
        gaze.testSink = nil
        gaze.isTesting = false
        island.forceExpanded = false
        island.videoMarker = nil

        overlay.onClick = nil
        let session = GazeTestSession(version: GazeFeatures.version, date: Date(), islandRect: gaze.islandRect(),
                                      frames: frames, anchors: anchors)
        GazeTestStore.save(session)
        let boundary = gaze.sensitivity.cameraBoundary
        let results = gaze.trainedEngines.map { GazeEvaluation.run($0, on: session, cameraBoundary: boundary) }
        Log.info("gaze: test finished, \(frames.count) frames, \(frames.filter { $0.values == nil }.count) without a face")
        for result in results { Log.info("gaze test: " + result.summary) }

        model.point = nil
        model.hint = nil
        model.instruction = "Gaze test results"
        model.lines = results.map(\.summary)
        model.stepLabel = "Click or press Esc to close"
        overlay.closesOnClick = true
    }

    private func finish() {
        task?.cancel()
        task = nil
        gaze.testSink = nil
        gaze.isTesting = false
        island.forceExpanded = false
        island.videoMarker = nil
        island.ignoresMouse = false
        overlay?.close()
        overlay = nil
    }
}

extension GazeController {
    /// Scores every engine on every recorded test (developer flag `--evaluate-gaze`).
    func evaluateRecordedTests() async {
        await loadStoredCalibration()
        let sessions = GazeTestStore.loadAll()
        Log.info("gaze eval: \(sessions.count) recorded tests, engines \(trainedEngines.map { type(of: $0).id })")
        for (name, session) in sessions {
            // Engines that read the sensitivity setting get one run per setting.
            let runs: [(engine: any GazeEngine, boundary: Double?, label: String)] = trainedEngines.flatMap { engine in
                let id = type(of: engine).id
                guard type(of: engine).usesSensitivity else { return [(engine: engine, boundary: Double?.none, label: id)] }
                return GazeSensitivity.allCases.map { (engine: engine, boundary: Double?.some($0.cameraBoundary), label: "\(id)·\($0.rawValue)") }
            }
            for (engine, boundary, id) in runs {
                var rows = ["time,step,target,tx,ty,stepTime,settled,face,x,y,zone,wants,blink,glitch,driftX,driftY,driftAnchors"]
                let result = GazeEvaluation.run(engine, on: session, cameraBoundary: boundary, label: id) { frame, output in
                    func n(_ v: Double?) -> String { v.map { String(format: "%.4f", $0) } ?? "" }
                    rows.append([n(frame.time), "\(frame.step)", frame.target.rawValue, n(frame.x), n(frame.y), n(frame.stepTime),
                                 frame.settled.map { $0 ? "1" : "0" } ?? "", frame.values == nil ? "0" : "1",
                                 n(output.point.map { Double($0.x) }), n(output.point.map { Double($0.y) }),
                                 output.zone?.rawValue ?? "", output.wantsExpanded ? "1" : "0",
                                 output.isBlinking ? "1" : "0", output.isGlitch ? "1" : "0",
                                 n(output.drift.map { Double($0.x) }), n(output.drift.map { Double($0.y) }),
                                 "\(output.driftAnchors)"].joined(separator: ","))
                }
                Log.info("gaze eval \(name): " + result.summary)
                let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/CineNotch-eval")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? rows.joined(separator: "\n").write(to: dir.appendingPathComponent("\(name)-\(id).csv"), atomically: true, encoding: .utf8)
            }
        }
    }
}
