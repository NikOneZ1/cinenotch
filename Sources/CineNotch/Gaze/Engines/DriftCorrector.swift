import CoreGraphics
import Foundation

/// Learns the offset between predicted and true gaze from anchors (clicks).
final class DriftCorrector {
    /// Clicks used for the estimate.
    private let keep = 10
    /// Older clicks no longer describe how the user sits.
    private let maxAge: TimeInterval = 15 * 60
    /// Where the eyes are around a click: they land on the target a little before it.
    /// A single frame is too noisy, so the prediction is the median over this window.
    private let before: TimeInterval = 0.4
    private let after: TimeInterval = 0.2
    /// A click this far from the current estimate means the user looked elsewhere while clicking.
    private let outlier = 0.3

    private var recent: [(time: TimeInterval, point: CGPoint)] = []
    private var pending: [GazeAnchor] = []
    private var residuals: [(time: TimeInterval, delta: CGPoint)] = []
    private var lastAnchor = -TimeInterval.infinity
    private(set) var offset = CGPoint.zero
    var count: Int { residuals.count }

    /// `uncorrected` is the tracker's gaze point at `time`, before any correction.
    func update(anchors: [GazeAnchor], uncorrected point: CGPoint, at time: TimeInterval) {
        recent.append((time, point))
        recent.removeAll { time - $0.time > before + after + 1 }
        for anchor in anchors where anchor.time > lastAnchor && anchor.time <= time {
            lastAnchor = anchor.time
            pending.append(anchor)
        }
        pending.removeAll { anchor in
            guard time >= anchor.time + after else { return false }
            let window = recent.filter { $0.time >= anchor.time - before && $0.time <= anchor.time + after }
            guard window.count >= 3 else { return true }
            let seen = CGPoint(x: Self.median(window.map { Double($0.point.x) }), y: Self.median(window.map { Double($0.point.y) }))
            let delta = CGPoint(x: anchor.x - seen.x, y: anchor.y - seen.y)
            // The first few clicks are taken as they are; after that, ones that disagree are skipped.
            if residuals.count < 3 || hypot(delta.x - offset.x, delta.y - offset.y) <= outlier {
                residuals.append((anchor.time, delta))
            }
            return true
        }
        residuals.removeAll { time - $0.time > maxAge }
        if residuals.count > keep { residuals.removeFirst(residuals.count - keep) }
        offset = residuals.isEmpty ? .zero
            : CGPoint(x: Self.median(residuals.map { Double($0.delta.x) }), y: Self.median(residuals.map { Double($0.delta.y) }))
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}
