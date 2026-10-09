import CoreGraphics
import Foundation

/// One version of the gaze pipeline: how it learns from calibration and how it turns frames
/// into decisions. New versions are added next to the current one and compared with it on the
/// same frames (live side by side, or on recorded gaze tests with `--evaluate-gaze`).
protocol GazeEngine: Sendable {
    static var id: String { get }
    static var title: String { get }
    /// Fits on calibration samples. Runs off the main thread.
    static func train(_ samples: [GazeSample], islandRect: CGRect) -> Self?
    var report: GazeTrainingReport { get }
    /// Fresh per-stream state (smoothing, dwell timers).
    func makeTracker() -> GazeTracker
    /// Takes the camera boundary from the sensitivity setting (`GazeContext.cameraBoundary`).
    static var usesSensitivity: Bool { get }
}

extension GazeEngine {
    static var usesSensitivity: Bool { false }
}

/// Stateful per-frame decision maker of one engine. Used from one thread.
protocol GazeTracker: AnyObject {
    func process(_ frame: GazeFeatures?, at time: TimeInterval, context: GazeContext) -> GazeOutput
}

struct GazeContext {
    /// The expanded island, screen-normalized (0...1, y down).
    var islandRect: CGRect
    /// Last keyboard, click or scroll activity, in the same clock as frame times.
    var lastUserInput: TimeInterval = -.infinity
    /// Moments the user was almost certainly looking at a known spot (mouse clicks), oldest
    /// first, none later than the current frame.
    var anchors: [GazeAnchor] = []
    /// The camera zone's lower edge from the sensitivity setting, for engines that use it (v8+).
    var cameraBoundary: Double?
}

/// "Looking here, now": a mouse click (people look at what they click).
struct GazeAnchor: Codable {
    /// Same clock as frame times.
    var time: TimeInterval
    /// Screen-normalized (0...1, y down).
    var x: Double
    var y: Double
}

struct GazeOutput: Codable {
    /// Smoothed gaze, screen-normalized (y down).
    var point: CGPoint?
    var zone: GazeZone?
    var wantsExpanded = false
    var isBlinking = false
    /// The frame was thrown away as a landmark glitch.
    var isGlitch = false
    /// 0...1 progress towards a reveal, for on-screen feedback.
    var charge = 0.0
    /// Correction for posture drift currently applied, and how many clicks it rests on.
    var drift: CGPoint?
    var driftAnchors = 0
}

enum GazeZone: String, Codable {
    /// Above the screen, around the camera.
    case camera
    /// On the (expanded) island.
    case video
    /// Anywhere else.
    case work
}

struct GazeTrainingReport: Sendable {
    var samplesUsed: Int
    /// Mean distance between target and held-out prediction, in screen heights.
    var error: Double
    /// Share of each target's held-out predictions that land in the right zone.
    var recognized: [GazeTarget: Double]
    /// Gaze above this (screen-normalized y) near the center counts as looking into the camera.
    var cameraMaxY: Double
    var lambda: Double
    var headWeight: Double
    /// Engine-specific details for the log.
    var notes: String?

    var summary: String {
        func percent(_ target: GazeTarget) -> String { "\(Int(((recognized[target] ?? 0) * 100).rounded()))%" }
        return "camera \(percent(.camera)) · video \(percent(.video)) · elsewhere \(percent(.work))"
    }
}

/// Helpers shared by engine versions.
enum GazeMath {
    /// The lens sits just above the screen; in screen heights.
    static let cameraY = -0.04
    static let cameraHalfWidth = 0.2
    static let islandMargin = 0.06

    static func zone(for point: CGPoint, cameraMaxY: Double, islandRect: CGRect) -> GazeZone {
        if point.y < cameraMaxY, abs(point.x - 0.5) < cameraHalfWidth { return .camera }
        if islandRect.insetBy(dx: -islandMargin, dy: -islandMargin).contains(point) { return .video }
        return .work
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    static func report(samples: [GazeSample], fit: GazeRegressor.Fit, cameraMaxY: Double, islandRect: CGRect) -> GazeTrainingReport {
        let pairs = Array(zip(samples, fit.heldOut))
        var recognized: [GazeTarget: Double] = [:]
        for target in GazeTarget.allCases {
            let mine = pairs.filter { $0.0.target == target }
            guard !mine.isEmpty else { continue }
            let hits = mine.filter {
                zone(for: $0.1, cameraMaxY: cameraMaxY, islandRect: islandRect).rawValue == target.rawValue
            }.count
            recognized[target] = Double(hits) / Double(mine.count)
        }
        let error = pairs.reduce(0.0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } / Double(max(pairs.count, 1))
        return GazeTrainingReport(samplesUsed: samples.count, error: error, recognized: recognized,
                                  cameraMaxY: cameraMaxY, lambda: fit.lambda, headWeight: fit.headWeight)
    }
}
