import AppKit
import CoreVideo
import QuartzCore

/// The video's colors, shrunk to a 16×9 image that the island blurs into a soft glow under
/// the expanded video (like YouTube's ambient mode).
@MainActor
final class AmbientGlow: ObservableObject {
    @Published private(set) var image: CGImage?
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    private static let enabledKey = "ambientGlow"
    private static let columns = 16, rows = 9
    /// Running average of the samples, so scene cuts fade instead of jumping.
    private var colors: [Double] = []
    private var lastSample: TimeInterval = 0

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Samples a frame at most ten times a second.
    func consider(_ surface: IOSurface) {
        let now = CACurrentMediaTime()
        guard isEnabled, now - lastSample >= 0.1 else { return }
        lastSample = now
        guard let sample = Self.sample(surface) else { return }
        if colors.count != sample.count {
            colors = sample
        } else {
            for i in colors.indices { colors[i] += (sample[i] - colors[i]) * 0.35 }
        }
        image = Self.makeImage(colors)
    }

    func reset() {
        colors = []
        image = nil
    }

    /// Average color of each cell, from a 4×4 grid of pixels per cell (BGRA frames).
    private static func sample(_ surface: IOSurface) -> [Double]? {
        guard surface.pixelFormat == kCVPixelFormatType_32BGRA else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let width = surface.width, height = surface.height, bytesPerRow = surface.bytesPerRow
        guard width > 0, height > 0 else { return nil }
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        var out = [Double](repeating: 0, count: columns * rows * 3)
        for row in 0..<rows {
            for column in 0..<columns {
                var r = 0, g = 0, b = 0
                for sy in 0..<4 {
                    let y = min(height - 1, Int((Double(row) + (Double(sy) + 0.5) / 4) * Double(height) / Double(rows)))
                    for sx in 0..<4 {
                        let x = min(width - 1, Int((Double(column) + (Double(sx) + 0.5) / 4) * Double(width) / Double(columns)))
                        let pixel = base + y * bytesPerRow + x * 4
                        b += Int(pixel[0])
                        g += Int(pixel[1])
                        r += Int(pixel[2])
                    }
                }
                let i = (row * columns + column) * 3
                out[i] = Double(r) / 16
                out[i + 1] = Double(g) / 16
                out[i + 2] = Double(b) / 16
            }
        }
        return out
    }

    private static func makeImage(_ colors: [Double]) -> CGImage? {
        var bytes = [UInt8](repeating: 255, count: columns * rows * 4)
        for i in 0..<(columns * rows) {
            bytes[i * 4] = UInt8(min(max(colors[i * 3], 0), 255))
            bytes[i * 4 + 1] = UInt8(min(max(colors[i * 3 + 1], 0), 255))
            bytes[i * 4 + 2] = UInt8(min(max(colors[i * 3 + 2], 0), 255))
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
                       space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
