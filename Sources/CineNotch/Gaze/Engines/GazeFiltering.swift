import CoreGraphics
import Foundation

/// Cleaning calibration data: a calibration step's first frames come while the eyes are still
/// on their way, blinks scramble the eye pictures, and Vision now and then loses the face for a
/// few frames (the nose jumps by a quarter of the eye distance between frames).
enum GazeCleaning {
    /// Frames per step skipped at its start (~0.27 s at 15 fps).
    private static let arrivalFrames = 4

    /// Calibration samples without arrival frames, blinks and landmark glitches.
    static func cleaned(_ samples: [GazeSample]) -> [GazeSample] {
        Dictionary(grouping: samples, by: \.step).values
            .flatMap { step -> [GazeSample] in
                let typical = GazeMath.median(step.map(\.openness))
                var kept: [GazeSample] = []
                var previous: GlitchKey?
                var glitchRun = 0
                for sample in step.dropFirst(arrivalFrames) where sample.openness >= typical * 0.7 {
                    let key = GlitchKey(values: sample.values)
                    // Same rule as live: a long run of "jumps" is the head having really moved.
                    if let previous, key.jumped(from: previous), glitchRun < 5 {
                        glitchRun += 1
                        continue
                    }
                    glitchRun = 0
                    previous = key
                    kept.append(sample)
                }
                return kept
            }
            .sorted { $0.step < $1.step }
    }
}

/// The landmark-derived numbers that jump when Vision loses track of the face.
struct GlitchKey {
    var roll: Double
    var noseA: Double
    var noseB: Double
    var eyeDistance: Double

    private static let indices = ["roll", "noseA", "noseB", "eyeDistance"].map { GazeFeatures.headNames.firstIndex(of: $0)! }

    init(head: [Double]) {
        roll = head[Self.indices[0]]
        noseA = head[Self.indices[1]]
        noseB = head[Self.indices[2]]
        eyeDistance = head[Self.indices[3]]
    }

    init(values: [Double]) {
        self.init(head: Array(values.suffix(GazeFeatures.headNames.count)))
    }

    /// Far beyond what a real head moves in one frame (~67 ms).
    func jumped(from other: GlitchKey) -> Bool {
        abs(roll - other.roll) > 0.12
            || abs(noseA - other.noseA) > 0.15
            || abs(noseB - other.noseB) > 0.15
            || abs(eyeDistance - other.eyeDistance) > 0.1 * max(other.eyeDistance, 1e-6)
    }
}

/// One Euro filter (Casiez et al.): the cutoff frequency rises with speed.
struct OneEuroFilter {
    var minCutoff = 0.8
    var beta = 1.0
    var derivativeCutoff = 1.0
    private var value: Double?
    private var derivative = 0.0
    private var time: TimeInterval?

    mutating func filter(_ x: Double, at t: TimeInterval) -> Double {
        guard let previous = value, let previousTime = time else {
            value = x
            time = t
            return x
        }
        let dt = max(t - previousTime, 1e-3)
        derivative += Self.alpha(derivativeCutoff, dt) * ((x - previous) / dt - derivative)
        let filtered = previous + Self.alpha(minCutoff + beta * abs(derivative), dt) * (x - previous)
        value = filtered
        time = t
        return filtered
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
