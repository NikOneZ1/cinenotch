import CoreGraphics
import CoreVideo
import Vision

/// What one camera frame says about the user's gaze.
///
/// The main signal is the eyes themselves: each eye is cut out along the line between the
/// eyes, scaled to `patchWidth`×`patchHeight` and brightness-normalized (the WebGazer
/// approach). Vision's single pupil point barely moves when only the eyes move; the pixels
/// do. But where you look is head direction plus eye direction: raise the head while looking
/// at the same spot and the eyes turn down in the head. So head pose comes along too, measured
/// every frame from where the nose, mouth, chin and brows sit relative to the line between
/// the eyes (in eye distances), which shifts as the head turns or nods.
struct GazeFeatures: Sendable {
    /// Bump when the vector layout changes; stored calibrations with another version are dropped.
    static let version = 3
    static let patchWidth = 20
    static let patchHeight = 10
    static let headNames = ["pitch", "yaw", "roll", "noseA", "noseB", "mouthA", "mouthB",
                            "faceAsym", "chinB", "browB", "eyesX", "eyesY", "eyeDistance"]

    /// Both eye patches, image-left eye first, each normalized to zero mean and unit variance.
    var pixels: [Float]
    /// Same order as `headNames`.
    var head: [Double]
    /// Eye height / eye width, averaged over both eyes; drops during blinks.
    var openness: Double

    var vector: [Double] { pixels.map(Double.init) + head }
}

/// Runs Vision face detection + landmarks. Not thread-safe: use from one queue.
///
/// Face detection is the expensive part (~17 ms at 720p vs ~6 ms for landmarks), so it runs
/// every `redetectEvery` frames; in between, the face box follows the landmarks.
final class FaceAnalyzer: @unchecked Sendable {
    private let faces: VNDetectFaceRectanglesRequest = {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        return request
    }()
    private let landmarks: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        return request
    }()
    /// Also how often Vision's own pitch/yaw refresh.
    private let redetectEvery = 5
    /// Smallest face box (a fraction of the image width) that is someone near the camera rather
    /// than a face on a poster across the room.
    private static let nearbyMinWidth: CGFloat = 0.07
    /// Widths of the faces near the camera at the last detection, largest first.
    private(set) var nearbyFaces: [CGFloat] = []
    private var tracked: VNFaceObservation?
    private var detected: VNFaceObservation?
    /// Where the landmarks' centroid sits inside a freshly detected face box (box-normalized).
    private var referenceCentroid: CGPoint?
    private var framesSinceDetection = 0

    func analyze(_ pixelBuffer: CVPixelBuffer) -> GazeFeatures? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            var face = tracked
            if face == nil || framesSinceDetection >= redetectEvery {
                try handler.perform([faces])
                let all = faces.results ?? []
                nearbyFaces = all.map(\.boundingBox.width).filter { $0 >= Self.nearbyMinWidth }.sorted(by: >)
                guard let found = all.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
                    tracked = nil
                    return nil
                }
                face = found
                detected = found
                referenceCentroid = nil
                framesSinceDetection = 0
            } else {
                framesSinceDetection += 1
            }
            guard let face, let detected else { return nil }
            landmarks.inputFaceObservations = [face]
            try handler.perform([landmarks])
            guard let marks = landmarks.results?.first?.landmarks, marks.confidence > 0.3 else {
                tracked = nil
                return nil
            }
            tracked = follow(face, marks: marks, pose: detected)
            return Self.features(pose: detected, marks: marks, pixelBuffer: pixelBuffer)
        } catch {
            tracked = nil
            return nil
        }
    }

    /// Shifts the face box so the landmarks stay where they were right after detection.
    private func follow(_ face: VNFaceObservation, marks: VNFaceLandmarks2D, pose: VNFaceObservation) -> VNFaceObservation? {
        guard let points = marks.allPoints?.normalizedPoints, !points.isEmpty else { return nil }
        let centroid = CGPoint(x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                               y: points.map(\.y).reduce(0, +) / CGFloat(points.count))
        guard let reference = referenceCentroid else {
            referenceCentroid = centroid
            return face
        }
        let box = face.boundingBox.offsetBy(dx: (centroid.x - reference.x) * face.boundingBox.width,
                                            dy: (centroid.y - reference.y) * face.boundingBox.height)
        return VNFaceObservation(requestRevision: VNDetectFaceRectanglesRequestRevision3, boundingBox: box,
                                 roll: pose.roll, yaw: pose.yaw, pitch: pose.pitch)
    }

    // MARK: Features

    /// An eye in image coordinates (Vision: origin bottom-left, y up).
    private struct Eye {
        var center: CGPoint
        var width: CGFloat
        var openness: Double
    }

    private static func features(pose: VNFaceObservation, marks: VNFaceLandmarks2D, pixelBuffer: CVPixelBuffer) -> GazeFeatures? {
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard let a = eye(marks.leftEye, imageSize: size), let b = eye(marks.rightEye, imageSize: size) else { return nil }
        let (left, right) = a.center.x < b.center.x ? (a, b) : (b, a)

        let dx = right.center.x - left.center.x, dy = right.center.y - left.center.y
        let distance = hypot(dx, dy)
        guard distance > 1 else { return nil }
        let axis = CGVector(dx: dx / distance, dy: dy / distance)
        let eyesMid = CGPoint(x: (left.center.x + right.center.x) / 2, y: (left.center.y + right.center.y) / 2)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        // Plane 0 of the bi-planar YCbCr frame is luma: a grayscale image.
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let luma = Luma(pixels: base.assumingMemoryBound(to: UInt8.self),
                        bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
                        width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                        height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
        let pixels = luma.patch(center: left.center, axis: axis, eyeWidth: left.width)
            + luma.patch(center: right.center, axis: axis, eyeWidth: right.width)

        // Face coordinates: a along the eye line, b perpendicular to it (up), in eye distances,
        // origin between the eyes. Roll-free by construction.
        let up = CGVector(dx: -axis.dy, dy: axis.dx)
        func local(_ p: CGPoint) -> (a: Double, b: Double) {
            let vx = p.x - eyesMid.x, vy = p.y - eyesMid.y
            return (Double((vx * axis.dx + vy * axis.dy) / distance), Double((vx * up.dx + vy * up.dy) / distance))
        }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [(a: Double, b: Double)] {
            (region?.pointsInImage(imageSize: size) ?? []).map(local)
        }
        func mean(_ pts: [(a: Double, b: Double)]) -> (a: Double, b: Double) {
            guard !pts.isEmpty else { return (0, 0) }
            return (pts.map(\.a).reduce(0, +) / Double(pts.count), pts.map(\.b).reduce(0, +) / Double(pts.count))
        }
        let nose = points(marks.noseCrest ?? marks.nose).min { $0.b < $1.b } ?? (0, 0)
        let mouth = mean(points(marks.outerLips))
        let contour = points(marks.faceContour)
        let faceAsym = (contour.map(\.a).max() ?? 0) + (contour.map(\.a).min() ?? 0)
        let chin = contour.map(\.b).min() ?? 0
        let brow = mean(points(marks.leftEyebrow) + points(marks.rightEyebrow))
        let head = [
            pose.pitch?.doubleValue ?? 0,
            pose.yaw?.doubleValue ?? 0,
            Double(atan2(axis.dy, axis.dx)),
            nose.a, nose.b, mouth.a, mouth.b, faceAsym, chin, brow.b,
            Double(eyesMid.x / size.width),
            Double(eyesMid.y / size.height),
            Double(distance / size.width),
        ]
        return GazeFeatures(pixels: pixels, head: head, openness: (left.openness + right.openness) / 2)
    }

    private static func eye(_ region: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> Eye? {
        guard let points = region?.pointsInImage(imageSize: imageSize), points.count >= 4,
              let inner = points.min(by: { $0.x < $1.x }), let outer = points.max(by: { $0.x < $1.x }) else { return nil }
        let width = hypot(outer.x - inner.x, outer.y - inner.y)
        guard width > 2 else { return nil }
        let ys = points.map(\.y)
        return Eye(center: CGPoint(x: (inner.x + outer.x) / 2, y: (inner.y + outer.y) / 2),
                   width: width,
                   openness: Double((ys.max()! - ys.min()!) / width))
    }
}

/// Bilinear sampling from a grayscale plane, addressed in Vision image coordinates.
private struct Luma {
    let pixels: UnsafePointer<UInt8>
    let bytesPerRow: Int
    let width: Int
    let height: Int

    /// A patch around `center`, its x axis along `axis` (the line between the eyes), covering
    /// 1.3 eye widths across and half that vertically.
    func patch(center: CGPoint, axis: CGVector, eyeWidth: CGFloat) -> [Float] {
        let w = GazeFeatures.patchWidth, h = GazeFeatures.patchHeight
        let spanX = eyeWidth * 1.3, spanY = spanX * 0.5
        var out = [Float](repeating: 0, count: w * h)
        for v in 0..<h {
            let up = 0.5 - (CGFloat(v) + 0.5) / CGFloat(h)
            for u in 0..<w {
                let along = (CGFloat(u) + 0.5) / CGFloat(w) - 0.5
                let x = center.x + axis.dx * along * spanX - axis.dy * up * spanY
                let y = center.y + axis.dy * along * spanX + axis.dx * up * spanY
                out[v * w + u] = sample(x: x, row: CGFloat(height - 1) - y)
            }
        }
        let mean = out.reduce(0, +) / Float(out.count)
        let variance = out.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(out.count)
        let scale = 1 / max(variance.squareRoot(), 1)
        return out.map { ($0 - mean) * scale }
    }

    private func sample(x: CGFloat, row: CGFloat) -> Float {
        let fx = min(max(x, 0), CGFloat(width - 2)), fy = min(max(row, 0), CGFloat(height - 2))
        let x0 = Int(fx), y0 = Int(fy)
        let tx = Float(fx - CGFloat(x0)), ty = Float(fy - CGFloat(y0))
        func p(_ x: Int, _ y: Int) -> Float { Float(pixels[y * bytesPerRow + x]) }
        let top = p(x0, y0) * (1 - tx) + p(x0 + 1, y0) * tx
        let bottom = p(x0, y0 + 1) * (1 - tx) + p(x0 + 1, y0 + 1) * tx
        return top * (1 - ty) + bottom * ty
    }
}
