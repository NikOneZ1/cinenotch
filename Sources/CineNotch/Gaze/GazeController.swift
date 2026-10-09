import AVFoundation
import AppKit
import Combine
import Foundation

/// Runs the camera and every gaze engine version side by side on the same frames.
/// The active engine decides when the island opens; the others are there to compare against.
@MainActor
final class GazeController: ObservableObject {
    /// Engine versions, oldest first; add a new one next to the current to compare them.
    /// Earlier experiments (v1–v7) are described under "What we tried" in the README.
    nonisolated static let engineTypes: [any GazeEngine.Type] = [GazeEngineV8.self]

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            resetTrackers()
            updateCamera()
        }
    }
    @Published var activeEngineID: String {
        didSet {
            UserDefaults.standard.set(activeEngineID, forKey: Self.engineKey)
            resetTrackers()
            Log.info("gaze: active engine \(activeEngineID)")
        }
    }
    @Published var sensitivity: GazeSensitivity {
        didSet {
            UserDefaults.standard.set(sensitivity.rawValue, forKey: Self.sensitivityKey)
            Log.info("gaze: sensitivity \(sensitivity.rawValue)")
        }
    }
    @Published var isHUDVisible = false {
        didSet {
            // Trackers that sat idle would resume with stale smoothing and votes.
            resetTrackers()
            updateCamera()
        }
    }
    /// The camera preview in Settings is on screen: the camera runs so the user can see what it sees.
    @Published var isPreviewVisible = false {
        didSet {
            guard isPreviewVisible != oldValue else { return }
            resetTrackers()
            updateCamera()
        }
    }
    /// The active engine's decision, gated by `isEnabled`.
    @Published private(set) var wantsExpanded = false
    /// The active engine's reveal progress, 0...1.
    @Published private(set) var charge = 0.0
    @Published private(set) var outputs: [String: GazeOutput] = [:]
    @Published private(set) var reports: [String: GazeTrainingReport] = [:]
    @Published private(set) var features: GazeFeatures?
    @Published private(set) var isCalibrated = false
    @Published private(set) var isCameraRunning = false

    var isPiPActive = false { didSet { updateCamera() } }
    var isCalibrating = false { didSet { updateCamera() } }
    var isTesting = false {
        didSet {
            resetTrackers()
            updateCamera()
        }
    }
    /// Receives every analyzed frame (nil = no face) while calibrating or testing.
    var calibrationSink: ((GazeFeatures?) -> Void)?
    var testSink: ((GazeFeatures?) -> Void)?
    /// The expanded island in screen-normalized coordinates (y down).
    var islandRect: () -> CGRect = { CGRect(x: 0.3, y: 0, width: 0.4, height: 0.45) }
    /// The screen gaze is measured on (the island's), in screen coordinates.
    var screenFrame: () -> CGRect = { NSScreen.main?.frame ?? .zero }

    let camera = CameraFeed()

    var engineIDs: [String] { Self.engineTypes.map { $0.id } }
    var trainedEngines: [any GazeEngine] { engineIDs.compactMap { engines[$0] } }
    var activeReport: GazeTrainingReport? { reports[activeEngineID] }

    static func title(of id: String) -> String {
        engineTypes.first { $0.id == id }?.title ?? id
    }

    private static let enabledKey = "gazeEnabled"
    private static let engineKey = "gazeEngine"
    private static let sensitivityKey = "gazeSensitivity"
    private var engines: [String: any GazeEngine] = [:]
    private var trackers: [String: GazeTracker] = [:]
    private var lastUserInput = -TimeInterval.infinity
    /// Recent clicks, the anchors for drift correction (v7).
    private var anchors: [GazeAnchor] = []
    private var monitors: [Any] = []
    private var csv: CSVLog?

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        let stored = UserDefaults.standard.string(forKey: Self.engineKey)
        activeEngineID = Self.engineTypes.contains { $0.id == stored } ? stored! : Self.engineTypes.last!.id
        sensitivity = GazeSensitivity(rawValue: UserDefaults.standard.string(forKey: Self.sensitivityKey) ?? "") ?? .strict
        let analyzer = FaceAnalyzer()
        camera.onFrame = { [weak self] pixelBuffer in
            let features = analyzer.analyze(pixelBuffer)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(features) } }
        }
        installActivityMonitors()
    }

    func loadStoredCalibration() async {
        guard let calibration = GazeCalibrationStore.load() else { return }
        await train(calibration.samples)
    }

    /// Trains every engine version on new calibration samples and stores them.
    func applyCalibration(_ samples: [GazeSample]) async -> [String: GazeTrainingReport] {
        await train(samples)
        if !engines.isEmpty {
            GazeCalibrationStore.save(GazeCalibrationData(version: GazeFeatures.version, date: Date(), samples: samples))
        }
        updateCamera()
        return reports
    }

    private func train(_ samples: [GazeSample]) async {
        let rect = islandRect()
        let started = Date()
        let trained = await withTaskGroup(of: (any GazeEngine)?.self) { group -> [any GazeEngine] in
            for type in Self.engineTypes {
                group.addTask { type.train(samples, islandRect: rect) }
            }
            var result: [any GazeEngine] = []
            for await engine in group {
                if let engine { result.append(engine) }
            }
            return result
        }
        engines = Dictionary(uniqueKeysWithValues: trained.map { (type(of: $0).id, $0) })
        reports = engines.mapValues(\.report)
        isCalibrated = !engines.isEmpty
        resetTrackers()
        for id in engineIDs {
            guard let report = reports[id] else {
                Log.info("gaze: \(id) failed to train")
                continue
            }
            Log.info(String(format: "gaze: %@ trained on %d samples, error %.3f, cameraMaxY %.3f, lambda %.0f, head weight %.0f: ",
                            id, report.samplesUsed, report.error, report.cameraMaxY, report.lambda, report.headWeight)
                     + report.summary + (report.notes.map { " | " + $0 } ?? ""))
        }
        Log.info(String(format: "gaze: training took %.1fs", Date().timeIntervalSince(started)))
        // A stored calibration loads after launch; the camera may be due now.
        updateCamera()
    }

    private func resetTrackers() {
        trackers = engines.mapValues { $0.makeTracker() }
        outputs = [:]
        wantsExpanded = false
        charge = 0
    }

    // MARK: Camera

    private func updateCamera() {
        let shouldRun = isCalibrating || isTesting || isHUDVisible || isPreviewVisible || (isEnabled && isCalibrated && isPiPActive)
        if shouldRun, !isCameraRunning {
            switch CameraAccess.status {
            case .authorized:
                camera.start()
                isCameraRunning = true
                Log.info("gaze: camera on")
            case .notDetermined:
                CameraAccess.request { [weak self] granted in
                    if granted { self?.updateCamera() }
                }
            default:
                Log.info("gaze: camera access denied")
                CameraAccess.openSettings()
            }
        } else if !shouldRun, isCameraRunning {
            camera.stop()
            isCameraRunning = false
            resetTrackers()
            Log.info("gaze: camera off")
        }
        updateCSV()
    }

    /// Typing, clicking and scrolling mean the user is busy with something on the screen.
    private func installActivityMonitors() {
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        let touch: () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.lastUserInput = ProcessInfo.processInfo.systemUptime }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { _ in touch() }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            touch()
            return event
        }) {
            monitors.append(monitor)
        }
        // People look at what they click: every click is a known gaze point.
        let click: () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.recordClick() }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { _ in click() }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { event in
            click()
            return event
        }) {
            monitors.append(monitor)
        }
    }

    private func recordClick() {
        guard isCameraRunning, !isCalibrating, !isTesting else { return }
        let frame = screenFrame(), mouse = NSEvent.mouseLocation
        guard frame.contains(mouse) else { return }
        anchors.append(GazeAnchor(time: ProcessInfo.processInfo.systemUptime,
                                  x: (mouse.x - frame.minX) / frame.width, y: (frame.maxY - mouse.y) / frame.height))
        if anchors.count > 30 { anchors.removeFirst(anchors.count - 30) }
    }

    // MARK: Frames

    private func handle(_ frame: GazeFeatures?) {
        guard isCameraRunning else { return }
        features = frame
        if isCalibrating {
            calibrationSink?(frame)
            return
        }
        if isTesting {
            testSink?(frame)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let context = GazeContext(islandRect: islandRect(), lastUserInput: lastUserInput, anchors: anchors,
                                  cameraBoundary: sensitivity.cameraBoundary)
        // Every engine side by side only while the debug panel shows them; otherwise just the active one.
        var newOutputs: [String: GazeOutput] = [:]
        for (id, tracker) in trackers where isHUDVisible || id == activeEngineID {
            newOutputs[id] = tracker.process(frame, at: now, context: context)
        }
        outputs = newOutputs

        let active = newOutputs[activeEngineID]
        let wants = isEnabled && (active?.wantsExpanded ?? false)
        if wants != wantsExpanded {
            wantsExpanded = wants
            Log.info("gaze: \(wants ? "reveal" : "collapse") (\(activeEngineID))")
        }
        let newCharge = isEnabled && !wants ? ((active?.charge ?? 0) * 10).rounded() / 10 : 0
        if newCharge != charge { charge = newCharge }
        log(frame, now: now)
    }

    // MARK: Debug log

    private func updateCSV() {
        if isHUDVisible, isCameraRunning, csv == nil {
            var header = ["time", "face", "openness"] + GazeFeatures.headNames
            for id in engineIDs { header += ["\(id)_x", "\(id)_y", "\(id)_zone", "\(id)_wants", "\(id)_blink", "\(id)_glitch"] }
            header += ["active", "enabled"]
            csv = CSVLog(name: "CineNotch-gaze.csv", header: header)
        } else if !(isHUDVisible && isCameraRunning) {
            csv = nil
        }
    }

    private func log(_ frame: GazeFeatures?, now: TimeInterval) {
        guard let csv else { return }
        func number(_ value: Double?) -> String { String(format: "%.4f", value ?? .nan) }
        var row = [String(format: "%.3f", now), frame == nil ? "0" : "1", number(frame?.openness)]
        row += (frame?.head ?? Array(repeating: .nan, count: GazeFeatures.headNames.count)).map { number($0) }
        for id in engineIDs {
            let output = outputs[id]
            row += [number(output?.point.map { Double($0.x) }), number(output?.point.map { Double($0.y) }),
                    output?.zone?.rawValue ?? "", output?.wantsExpanded == true ? "1" : "0",
                    output?.isBlinking == true ? "1" : "0", output?.isGlitch == true ? "1" : "0"]
        }
        row += [activeEngineID, isEnabled ? "1" : "0"]
        csv.write(row)
    }
}

/// Appends rows to ~/Library/Logs/<name>, recreated on every open.
final class CSVLog: @unchecked Sendable {
    private let handle: FileHandle?
    private let queue = DispatchQueue(label: "com.cinenotch.csv")

    init(name: String, header: [String]) {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(name)")
        FileManager.default.createFile(atPath: url.path, contents: Data((header.joined(separator: ",") + "\n").utf8))
        handle = try? FileHandle(forWritingTo: url)
        handle?.seekToEndOfFile()
    }

    func write(_ row: [String]) {
        let line = row.joined(separator: ",") + "\n"
        queue.async { [handle] in handle?.write(Data(line.utf8)) }
    }

    deinit {
        let handle = handle
        queue.async { try? handle?.close() }
    }
}
