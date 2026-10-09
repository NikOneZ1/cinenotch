import Accelerate
import CoreGraphics
import Foundation

/// What a calibration target stands for.
enum GazeTarget: String, Codable, CaseIterable, Identifiable {
    /// Looking into the camera: the gesture that reveals the video.
    case camera
    /// Looking at the expanded video: keeps it open.
    case video
    /// Looking anywhere else on the screen: lets it collapse.
    case work

    var id: String { rawValue }
}

struct GazeSample: Codable {
    var target: GazeTarget
    var step: Int
    /// Where the user was looking, in screen-normalized coordinates (0...1, y down;
    /// the camera sits slightly above the screen, at negative y).
    var x: Double
    var y: Double
    var openness: Double
    var values: [Double]
}

struct GazeCalibrationData: Codable {
    var version: Int
    var date: Date
    var samples: [GazeSample]
}

/// Ridge regression from gaze features to a point on the screen, fitted per user.
///
/// The last `headCount` features (head pose) get their own, lighter penalty: there are few of
/// them and they are reliable, unlike the hundreds of noisy eye pixels. Both the overall
/// strength and the head weight are picked by cross-validation over calibration steps.
struct GazeRegressor: Sendable {
    private let mean: [Double]
    /// Per-feature divisor: standard deviation over the group weight.
    private let scale: [Double]
    private let weightsX: [Double]
    private let weightsY: [Double]
    private let biasX: Double
    private let biasY: Double

    func predict(_ values: [Double]) -> CGPoint {
        guard values.count == mean.count else { return .zero }
        var x = biasX, y = biasY
        for i in 0..<values.count {
            let z = (values[i] - mean[i]) / scale[i]
            x += z * weightsX[i]
            y += z * weightsY[i]
        }
        return CGPoint(x: x, y: y)
    }

    struct Fit: Sendable {
        var model: GazeRegressor
        var lambda: Double
        var headWeight: Double
        /// Prediction for every sample made by a model that didn't see that sample's step.
        var heldOut: [CGPoint]
    }

    /// `targets` picks what to learn per sample; by default where the user was looking.
    static func fit(_ samples: [GazeSample], headCount: Int,
                    targets: (GazeSample) -> (x: Double, y: Double) = { ($0.x, $0.y) }) -> Fit? {
        let n = samples.count
        guard n >= 20, let d = samples.first?.values.count, d > headCount else { return nil }
        let p = d - headCount

        let mean = (0..<d).map { j in samples.reduce(0) { $0 + $1.values[j] } / Double(n) }
        let std = (0..<d).map { j in
            max((samples.reduce(0) { $0 + pow($1.values[j] - mean[j], 2) } / Double(n)).squareRoot(), 1e-6)
        }
        // Standardized eye-pixel and head blocks, row-major.
        var pixels = [Double](repeating: 0, count: n * p)
        var head = [Double](repeating: 0, count: n * headCount)
        for i in 0..<n {
            for j in 0..<p { pixels[i * p + j] = (samples[i].values[j] - mean[j]) / std[j] }
            for j in 0..<headCount { head[i * headCount + j] = (samples[i].values[p + j] - mean[p + j]) / std[p + j] }
        }
        let pixelGram = gram(pixels, rows: n, columns: p)
        let headGram = gram(head, rows: n, columns: headCount)

        let tx = samples.map { targets($0).x }, ty = samples.map { targets($0).y }
        // Six folds of whole steps; steps of one target are interleaved, so a fold never takes
        // all of them.
        let folds = 6
        let fold = samples.map { $0.step % folds }

        var best: (lambda: Double, headWeight: Double, error: Double, heldOut: [CGPoint])?
        for headWeight in [1.0, 3.0, 10.0] {
            let w2 = headWeight * headWeight
            let k = zip(pixelGram, headGram).map { $0 + w2 * $1 }
            let meanDiagonal = (0..<n).reduce(0.0) { $0 + k[$1 * n + $1] } / Double(n)
            for factor in [0.003, 0.01, 0.03, 0.1, 0.3] {
                let lambda = factor * meanDiagonal
                var heldOut = [CGPoint](repeating: .zero, count: n)
                var failed = false
                for f in 0..<folds {
                    let train = (0..<n).filter { fold[$0] != f }
                    let test = (0..<n).filter { fold[$0] == f }
                    guard !test.isEmpty else { continue }
                    guard let solution = solveDual(gram: k, n: n, rows: train, tx: tx, ty: ty, lambda: lambda) else {
                        failed = true
                        break
                    }
                    for t in test {
                        var px = solution.meanX, py = solution.meanY
                        for (index, r) in train.enumerated() {
                            px += k[t * n + r] * solution.ax[index]
                            py += k[t * n + r] * solution.ay[index]
                        }
                        heldOut[t] = CGPoint(x: px, y: py)
                    }
                }
                guard !failed else { continue }
                let error = (0..<n).reduce(0.0) { $0 + hypot(heldOut[$1].x - tx[$1], heldOut[$1].y - ty[$1]) } / Double(n)
                if best == nil || error < best!.error { best = (lambda, headWeight, error, heldOut) }
            }
        }
        guard let best else { return nil }

        let w2 = best.headWeight * best.headWeight
        let k = zip(pixelGram, headGram).map { $0 + w2 * $1 }
        guard let solution = solveDual(gram: k, n: n, rows: Array(0..<n), tx: tx, ty: ty, lambda: best.lambda) else { return nil }
        // Back to primal weights (W = Zᵀa over the weighted features) so a frame costs one dot product.
        var wx = [Double](repeating: 0, count: d), wy = [Double](repeating: 0, count: d)
        for i in 0..<n {
            let ax = solution.ax[i], ay = solution.ay[i]
            for j in 0..<p {
                wx[j] += pixels[i * p + j] * ax
                wy[j] += pixels[i * p + j] * ay
            }
            for j in 0..<headCount {
                let z = head[i * headCount + j] * best.headWeight
                wx[p + j] += z * ax
                wy[p + j] += z * ay
            }
        }
        let scale = (0..<d).map { $0 < p ? std[$0] : std[$0] / best.headWeight }
        let model = GazeRegressor(mean: mean, scale: scale, weightsX: wx, weightsY: wy,
                                  biasX: solution.meanX, biasY: solution.meanY)
        return Fit(model: model, lambda: best.lambda, headWeight: best.headWeight, heldOut: best.heldOut)
    }

    /// Z Zᵀ for a row-major `rows`×`columns` matrix.
    private static func gram(_ z: [Double], rows: Int, columns: Int) -> [Double] {
        var transposed = [Double](repeating: 0, count: rows * columns)
        vDSP_mtransD(z, 1, &transposed, 1, vDSP_Length(columns), vDSP_Length(rows))
        var result = [Double](repeating: 0, count: rows * rows)
        vDSP_mmulD(z, 1, transposed, 1, &result, 1, vDSP_Length(rows), vDSP_Length(rows), vDSP_Length(columns))
        return result
    }

    private struct DualSolution {
        var ax: [Double]
        var ay: [Double]
        var meanX: Double
        var meanY: Double
    }

    /// Solves (K[rows, rows] + λI) a = t[rows] - mean(t[rows]) for both coordinates.
    private static func solveDual(gram: [Double], n: Int, rows: [Int], tx: [Double], ty: [Double],
                                  lambda: Double) -> DualSolution? {
        let m = rows.count
        let meanX = rows.reduce(0) { $0 + tx[$1] } / Double(m)
        let meanY = rows.reduce(0) { $0 + ty[$1] } / Double(m)
        var a = [Double](repeating: 0, count: m * m)
        for (i, r) in rows.enumerated() {
            for (k, c) in rows.enumerated() { a[i * m + k] = gram[r * n + c] }
            a[i * m + i] += lambda
        }
        guard cholesky(&a, m) else { return nil }
        return DualSolution(ax: choleskySolve(a, m, rows.map { tx[$0] - meanX }),
                            ay: choleskySolve(a, m, rows.map { ty[$0] - meanY }),
                            meanX: meanX, meanY: meanY)
    }

    /// In-place: the lower triangle of `a` becomes L with L Lᵀ = a.
    private static func cholesky(_ a: inout [Double], _ n: Int) -> Bool {
        a.withUnsafeMutableBufferPointer { l in
            for j in 0..<n {
                var s = l[j * n + j]
                for k in 0..<j { s -= l[j * n + k] * l[j * n + k] }
                guard s > 1e-12 else { return false }
                let diag = s.squareRoot()
                l[j * n + j] = diag
                for i in (j + 1)..<n {
                    var t = l[i * n + j]
                    for k in 0..<j { t -= l[i * n + k] * l[j * n + k] }
                    l[i * n + j] = t / diag
                }
            }
            return true
        }
    }

    private static func choleskySolve(_ l: [Double], _ n: Int, _ b: [Double]) -> [Double] {
        var y = b
        for i in 0..<n {
            for k in 0..<i { y[i] -= l[i * n + k] * y[k] }
            y[i] /= l[i * n + i]
        }
        var x = y
        for i in stride(from: n - 1, through: 0, by: -1) {
            for k in (i + 1)..<n { x[i] -= l[k * n + i] * x[k] }
            x[i] /= l[i * n + i]
        }
        return x
    }
}

enum GazeCalibrationStore {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CineNotch", isDirectory: true)
        return dir.appendingPathComponent("gaze-calibration.json")
    }

    static func load() -> GazeCalibrationData? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let calibration = try? decoder.decode(GazeCalibrationData.self, from: data),
              calibration.version == GazeFeatures.version else { return nil }
        return calibration
    }

    static func save(_ calibration: GazeCalibrationData) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(calibration).write(to: url)
        } catch {
            Log.info("gaze: failed to save calibration: \(error.localizedDescription)")
        }
    }
}
