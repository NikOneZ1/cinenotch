// Draws the app icon (the mascot: a black island with lime eyes on warm paper) and writes
// Resources/AppIcon.icns.
//
//   swift scripts/make-icon.swift            # writes Resources/AppIcon.icns
//   swift scripts/make-icon.swift out.png    # also saves the 1024 px master as a PNG
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// The icon on a 1024 pt canvas, macOS grid: an 824 pt rounded square with room for its shadow.
func draw(_ cg: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Tile with a soft drop shadow.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
    cg.addPath(tilePath)
    cg.setFillColor(color(0xF1EDE3))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(tilePath)
    cg.clip()
    let paper = CGGradient(colorsSpace: nil, colors: [color(0xFAF7F0), color(0xE9E4D7)] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(paper, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

    // The island.
    let body = CGRect(x: 512 - 300, y: 512 - 138 - 10, width: 600, height: 276)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 138, cornerHeight: 138, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -26), blur: 46, color: color(0x3A2E14, 0.32))
    cg.addPath(bodyPath)
    cg.setFillColor(color(0x0B0B0A))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(bodyPath)
    cg.clip()
    let ink = CGGradient(colorsSpace: nil, colors: [color(0x2A2A28), color(0x0B0B0A), color(0x050505)] as CFArray,
                         locations: [0, 0.45, 1])!
    cg.drawLinearGradient(ink, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
    cg.restoreGState()

    // Eyes, glowing, glancing a little to the side; the catchlights make them read as eyes.
    let eyeSize = CGSize(width: 62, height: 92)
    for dx in [-80.0, 80.0] {
        let eye = CGRect(x: 512 + 16 + dx - eyeSize.width / 2, y: body.midY + 4 - eyeSize.height / 2,
                         width: eyeSize.width, height: eyeSize.height)
        let path = CGPath(ellipseIn: eye, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 46, color: color(0xC6F432, 0.85))
        cg.addPath(path)
        cg.setFillColor(color(0xC6F432))
        cg.fillPath()
        cg.restoreGState()
        let glint = CGRect(x: eye.minX + 13, y: eye.maxY - 34, width: 18, height: 18)
        cg.setFillColor(color(0xFFFFFF, 0.9))
        cg.fillEllipse(in: glint)
    }
    cg.restoreGState()
}

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(cg)
    return rep
}

func png(_ rep: NSBitmapImageRep) -> Data { rep.representation(using: .png, properties: [:])! }

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try png(render(pixels: size)).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(render(pixels: size * 2)).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else {
    print("iconutil failed")
    exit(1)
}
print("wrote \(output.path)")

if CommandLine.arguments.count > 1 {
    let master = URL(fileURLWithPath: CommandLine.arguments[1])
    try png(render(pixels: 1024)).write(to: master)
    print("wrote \(master.path)")
}
