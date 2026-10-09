import CoreGraphics
import CoreVideo
import Foundation
import IOSurface

/// `--debug-fake-pip`: a drawn landscape that cycles through four palettes, delivered as
/// BGRA IOSurfaces like ScreenCaptureKit's, so the island (and its glow) can be worked on
/// without Safari.
final class FakeVideo {
    private let width: Int
    private let height: Int
    /// A few surfaces in turn: a layer doesn't redraw when it's handed the same one again.
    private var surfaces: [IOSurface] = []
    private var next = 0

    private struct Palette {
        var top, bottom, sun, hill1, hill2, hill3: (CGFloat, CGFloat, CGFloat)
    }

    private static func rgb(_ hex: UInt32) -> (CGFloat, CGFloat, CGFloat) {
        (CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
    }

    private static let palettes: [Palette] = [
        Palette(top: rgb(0x2A1B4D), bottom: rgb(0xFF8A5B), sun: rgb(0xFFE39A), hill1: rgb(0x7A4777), hill2: rgb(0x4A2B5E), hill3: rgb(0x21153A)),
        Palette(top: rgb(0x2F7FD0), bottom: rgb(0xBEE5FF), sun: rgb(0xFFF8DD), hill1: rgb(0x55B7A8), hill2: rgb(0x2D7E87), hill3: rgb(0x164659)),
        Palette(top: rgb(0x6FBF9C), bottom: rgb(0xEAF6C9), sun: rgb(0xFFFBE3), hill1: rgb(0x8DC152), hill2: rgb(0x4C8939), hill3: rgb(0x204F28)),
        Palette(top: rgb(0x050815), bottom: rgb(0x27407F), sun: rgb(0xE9EDFF), hill1: rgb(0x2D3868), hill2: rgb(0x1A2249), hill3: rgb(0x0B0F27)),
    ]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let properties: [IOSurfacePropertyKey: Any] = [
            .width: width, .height: height, .bytesPerElement: 4, .bytesPerRow: width * 4,
            .pixelFormat: kCVPixelFormatType_32BGRA,
        ]
        surfaces = (0..<3).compactMap { _ in IOSurface(properties: properties) }
    }

    func frame(at t: Double) -> IOSurface? {
        guard !surfaces.isEmpty else { return nil }
        let surface = surfaces[next]
        next = (next + 1) % surfaces.count
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: surface.bytesPerRow, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        // Draw in a 560×315 canvas with the origin at the top left.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / 560, y: -CGFloat(height) / 315)
        draw(context, t: t)
        return surface
    }

    private func draw(_ cg: CGContext, t: Double) {
        let w: CGFloat = 560, h: CGFloat = 315
        let period = 7.0, hold = 5.0
        let u = t / period, index = Int(u) % 4, within = (u - floor(u)) * period
        let k = within < hold ? 0 : CGFloat(smooth((within - hold) / (period - hold)))
        let a = Self.palettes[index], b = Self.palettes[(index + 1) % 4]
        func mix(_ x: (CGFloat, CGFloat, CGFloat), _ y: (CGFloat, CGFloat, CGFloat), alpha: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: x.0 + (y.0 - x.0) * k, green: x.1 + (y.1 - x.1) * k, blue: x.2 + (y.2 - x.2) * k, alpha: alpha)
        }
        let night: CGFloat = index == 3 ? 1 - k : (index == 2 ? k : 0)

        let sky = CGGradient(colorsSpace: nil, colors: [mix(a.top, b.top), mix(a.bottom, b.bottom)] as CFArray, locations: [0, 0.8])!
        cg.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: h), options: [.drawsAfterEndLocation])

        if night > 0.01 {
            cg.setFillColor(CGColor(gray: 1, alpha: 0.85 * night))
            var seed: UInt64 = 7
            for _ in 0..<70 {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let x = CGFloat(seed >> 33 & 0xFFFF) / 65535 * w
                let y = CGFloat(seed >> 17 & 0xFFFF) / 65535 * h * 0.55
                cg.fill(CGRect(x: x, y: y, width: 1.4, height: 1.4))
            }
        }

        let sun = CGPoint(x: w * 0.66 + CGFloat(sin(t * 0.07)) * 24, y: h * 0.38 + CGFloat(cos(t * 0.05)) * 8)
        let glow = CGGradient(colorsSpace: nil, colors: [mix(a.sun, b.sun, alpha: 0.55), mix(a.sun, b.sun, alpha: 0)] as CFArray, locations: [0, 1])!
        cg.drawRadialGradient(glow, startCenter: sun, startRadius: 8, endCenter: sun, endRadius: 130, options: [])
        cg.setFillColor(mix(a.sun, b.sun))
        cg.fillEllipse(in: CGRect(x: sun.x - 28, y: sun.y - 28, width: 56, height: 56))

        cg.setFillColor(CGColor(gray: 1, alpha: 0.3 * (1 - night)))
        for j in 0..<4 {
            let x = CGFloat((Double(j) * 190 + t * (10 + Double(j) * 4)).truncatingRemainder(dividingBy: Double(w) + 240)) - 120
            let y = CGFloat(46 + j * 22)
            cg.fillEllipse(in: CGRect(x: x - CGFloat(58 + j * 8), y: y - 13, width: CGFloat(116 + j * 16), height: 26))
            cg.fillEllipse(in: CGRect(x: x + 30 - 38, y: y - 8 - 11, width: 76, height: 22))
        }

        hill(cg, mix(a.hill1, b.hill1), base: h * 0.62, amplitude: 18, frequency: 0.010, offset: t * 10, phase: 0, w: w, h: h)
        hill(cg, mix(a.hill2, b.hill2), base: h * 0.73, amplitude: 22, frequency: 0.007, offset: t * 20, phase: 2, w: w, h: h)
        hill(cg, mix(a.hill3, b.hill3), base: h * 0.85, amplitude: 16, frequency: 0.013, offset: t * 44, phase: 4, w: w, h: h)
    }

    private func hill(_ cg: CGContext, _ color: CGColor, base: CGFloat, amplitude: CGFloat, frequency: Double,
                      offset: Double, phase: Double, w: CGFloat, h: CGFloat) {
        cg.setFillColor(color)
        cg.beginPath()
        cg.move(to: CGPoint(x: 0, y: h))
        var x: CGFloat = 0
        while x <= w + 8 {
            let v = Double(x) + offset
            let y = base + CGFloat(sin(v * frequency + phase)) * amplitude + CGFloat(sin(v * frequency * 2.3 + phase * 1.7)) * amplitude * 0.45
            cg.addLine(to: CGPoint(x: x, y: y))
            x += 8
        }
        cg.addLine(to: CGPoint(x: w, y: h))
        cg.closePath()
        cg.fillPath()
    }

    private func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
