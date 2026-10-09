import CoreGraphics
import Foundation

/// How readily a glance counts as looking into the camera: the camera zone's lower edge,
/// screen-normalized y after drift correction. Stricter means fewer stray reveals and the
/// occasional glance that needs repeating; more sensitive the other way round. Recorded tests
/// put the boundary that a calibration could suggest well off the mark, so it is a setting.
enum GazeSensitivity: String, CaseIterable {
    case strict
    case balanced
    case sensitive

    var title: String {
        switch self {
        case .strict: return "Strict (fewer accidental reveals)"
        case .balanced: return "Balanced"
        case .sensitive: return "Sensitive (fewer missed glances)"
        }
    }

    var cameraBoundary: Double {
        switch self {
        case .strict: return 0.06
        case .balanced: return 0.10
        case .sensitive: return 0.16
        }
    }
}

/// v8: eye pixels + head pose → ridge regression to a point on the screen; landmark glitches,
/// arrival frames and blinks dropped; median + One Euro smoothing; reveal and collapse by vote;
/// posture drift corrected from mouse clicks; the camera boundary from the sensitivity setting.
///
/// Versions v1–v7 (thresholds from calibration, a camera classifier, a pretrained gaze network)
/// lost to this one on recorded tests; see "What we tried" in the README.
struct GazeEngineV8: GazeEngine {
    static let id = "v8"
    static let title = "v8 · eye pixels + click drift correction"
    static let usesSensitivity = true

    let model: GazeRegressor
    let baselineOpenness: Double
    let report: GazeTrainingReport

    static func train(_ samples: [GazeSample], islandRect: CGRect) -> GazeEngineV8? {
        let clean = GazeCleaning.cleaned(samples)
        guard let fit = GazeRegressor.fit(clean, headCount: GazeFeatures.headNames.count) else { return nil }
        let boundary = GazeSensitivity.balanced.cameraBoundary
        var report = GazeMath.report(samples: clean, fit: fit, cameraMaxY: boundary, islandRect: islandRect)
        report.notes = "camera boundary from the sensitivity setting; posture drift corrected by clicks"
        return GazeEngineV8(model: fit.model, baselineOpenness: GazeMath.median(clean.map(\.openness)), report: report)
    }

    func makeTracker() -> GazeTracker {
        let model = self.model
        return FilteredGazeTracker(baselineOpenness: baselineOpenness, drift: DriftCorrector(),
                                   cameraBoundary: { $0.cameraBoundary ?? GazeSensitivity.balanced.cameraBoundary },
                                   predict: { model.predict($0.vector) })
    }
}

/// v2's per-frame pipeline (glitch filter, blink skip, median + One Euro smoothing, voting),
/// with any predictor, an optional drift correction, and the camera boundary per frame.
final class FilteredGazeTracker: GazeTracker {
    private let predict: (GazeFeatures) -> CGPoint?
    private let baselineOpenness: Double
    private let drift: DriftCorrector?
    private let cameraBoundary: (GazeContext) -> Double
    private let noFaceTimeout: TimeInterval = 1.5
    private let blinkRatio = 0.7
    private let fps = 15.0

    private var output = GazeOutput()
    private var recentOpenness: [Double] = []
    private var lastKey: GlitchKey?
    private var glitchRun = 0
    private var recentRaw: [CGPoint] = []
    private var filterX = OneEuroFilter()
    private var filterY = OneEuroFilter()
    private var history: [(time: TimeInterval, zone: GazeZone)] = []
    private var lastFace = -TimeInterval.infinity

    init(baselineOpenness: Double, drift: DriftCorrector?, cameraBoundary: @escaping (GazeContext) -> Double,
         predict: @escaping (GazeFeatures) -> CGPoint?) {
        self.baselineOpenness = baselineOpenness
        self.drift = drift
        self.cameraBoundary = cameraBoundary
        self.predict = predict
    }

    func process(_ frame: GazeFeatures?, at time: TimeInterval, context: GazeContext) -> GazeOutput {
        output.isGlitch = false
        output.isBlinking = false
        guard let frame else {
            resetFilters()
            output.point = nil
            output.zone = nil
            output.charge = 0
            if output.wantsExpanded, time - lastFace > noFaceTimeout { output.wantsExpanded = false }
            return output
        }
        lastFace = time

        let key = GlitchKey(head: frame.head)
        if let lastKey, key.jumped(from: lastKey), glitchRun < 5 {
            glitchRun += 1
            output.isGlitch = true
            return output
        }
        glitchRun = 0
        lastKey = key

        recentOpenness.append(frame.openness)
        if recentOpenness.count > 30 { recentOpenness.removeFirst() }
        let typical = recentOpenness.count >= 10 ? GazeMath.median(recentOpenness) : baselineOpenness
        output.isBlinking = frame.openness < typical * blinkRatio
        guard !output.isBlinking, let raw = predict(frame) else { return output }

        recentRaw.append(raw)
        if recentRaw.count > 3 { recentRaw.removeFirst() }
        let median = CGPoint(x: GazeMath.median(recentRaw.map { Double($0.x) }),
                             y: GazeMath.median(recentRaw.map { Double($0.y) }))
        var point = CGPoint(x: filterX.filter(median.x, at: time), y: filterY.filter(median.y, at: time))
        if let drift {
            drift.update(anchors: context.anchors, uncorrected: point, at: time)
            point = CGPoint(x: point.x + drift.offset.x, y: point.y + drift.offset.y)
            output.drift = drift.offset
            output.driftAnchors = drift.count
        }
        output.point = point
        let zone = GazeMath.zone(for: point, cameraMaxY: cameraBoundary(context), islandRect: context.islandRect)
        output.zone = zone

        history.append((time, zone))
        history.removeAll { time - $0.time > 1.0 }

        if !output.wantsExpanded {
            let busy = time - context.lastUserInput < 1.0
            let window = busy ? 0.6 : 0.35
            let needed = busy ? 0.85 : 0.7
            let (share, count) = vote(for: .camera, within: window, now: time)
            output.charge = zone == .camera ? min(1, share / needed) : 0
            if count >= Int(window * fps * 0.6), share >= needed {
                output.wantsExpanded = true
                output.charge = 0
            }
        } else {
            output.charge = 0
            let (share, count) = vote(for: .work, within: 0.8, now: time)
            if count >= Int(0.8 * fps * 0.6), share >= 0.75 { output.wantsExpanded = false }
        }
        return output
    }

    private func vote(for zone: GazeZone, within window: TimeInterval, now: TimeInterval) -> (share: Double, count: Int) {
        let recent = history.filter { now - $0.time <= window }
        guard !recent.isEmpty else { return (0, 0) }
        return (Double(recent.filter { $0.zone == zone }.count) / Double(recent.count), recent.count)
    }

    private func resetFilters() {
        recentRaw = []
        filterX = OneEuroFilter()
        filterY = OneEuroFilter()
        history = []
        lastKey = nil
        glitchRun = 0
    }
}
