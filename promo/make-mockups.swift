// Renders promo images of CineNotch on a notched MacBook from real island captures.
//
//   ./scripts/run.sh --debug-notch --debug-cycle --debug-island-png /tmp/island   (with a PiP video playing)
//   swift promo/make-mockups.swift /tmp/island promo/out
//
// Inputs: island-expand.png and island-collapse.png (the island window alone, 2x, transparent).
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: make-mockups.swift <island captures dir> <output dir>")
    exit(1)
}
let inputDir = URL(fileURLWithPath: args[1])
let outputDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// MacBook Pro 14" at its default resolution, in points; the notch as CineNotch draws it.
let screenSize = CGSize(width: 1512, height: 982)
let notch = CGSize(width: 185, height: 32)
let pixelScale: CGFloat = 2

func loadIsland(_ name: String) -> NSImage? {
    guard let rep = NSImageRep(contentsOf: inputDir.appendingPathComponent("island-\(name).png")) else { return nil }
    let image = NSImage(size: CGSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2))
    image.addRepresentation(rep)
    return image
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws into a bitmap with a top-left origin.
func render(_ size: CGSize, scale: CGFloat = pixelScale, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func image(of rep: NSBitmapImageRep) -> NSImage {
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    let url = outputDir.appendingPathComponent(name)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
    print("wrote \(url.path) (\(rep.pixelsWide)×\(rep.pixelsHigh))")
}

func text(_ string: String, at point: CGPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
    (string as NSString).draw(at: point, withAttributes: attributes)
}

func textWidth(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
    (string as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width
}

func symbol(_ name: String, at rect: CGRect, color: NSColor, weight: NSFont.Weight = .regular) {
    let config = NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    let fitted = CGSize(width: rect.height * image.size.width / image.size.height, height: rect.height)
    image.draw(in: CGRect(x: rect.midX - fitted.width / 2, y: rect.minY, width: fitted.width, height: fitted.height),
               from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: Screen

/// The desktop of a notched MacBook: wallpaper, a browser window with an article, the menu bar
/// around the notch, and the island captured from the app.
func screen(island: NSImage?) -> NSBitmapImageRep {
    render(screenSize) { cg in
        // Wallpaper: soft warm-to-cool gradient with a couple of glows.
        let base = CGGradient(colorsSpace: nil, colors: [color(0xF6C8A8).cgColor, color(0xE8A3C4).cgColor, color(0x9CB8F0).cgColor] as CFArray,
                              locations: [0, 0.5, 1])!
        cg.drawLinearGradient(base, start: .zero, end: CGPoint(x: screenSize.width, y: screenSize.height), options: [])
        for (center, radius, hex) in [(CGPoint(x: 260, y: 820), 520.0, 0xFFE3B0 as UInt32), (CGPoint(x: 1300, y: 160), 600.0, 0x8FA8FF)] {
            let glow = CGGradient(colorsSpace: nil, colors: [color(hex, 0.75).cgColor, color(hex, 0).cgColor] as CFArray, locations: [0, 1])!
            cg.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
        }

        // A browser window with an article: the thing the video used to cover.
        let window = CGRect(x: 150, y: 74, width: 1212, height: 860)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: 18), blur: 50, color: color(0x000000, 0.28).cgColor)
        cg.addPath(roundedRect(window, 12))
        cg.setFillColor(color(0xFFFFFF).cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(roundedRect(window, 12))
        cg.clip()
        cg.setFillColor(color(0xF3F3F5).cgColor)
        cg.fill(CGRect(x: window.minX, y: window.minY, width: window.width, height: 52))
        cg.setFillColor(color(0xDEDEE2).cgColor)
        cg.fill(CGRect(x: window.minX, y: window.minY + 52, width: window.width, height: 1))
        for (i, hex) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
            cg.setFillColor(color(UInt32(hex)).cgColor)
            cg.fillEllipse(in: CGRect(x: window.minX + 20 + CGFloat(i) * 20, y: window.minY + 20, width: 12, height: 12))
        }
        let url = CGRect(x: window.midX - 230, y: window.minY + 12, width: 460, height: 28)
        cg.addPath(roundedRect(url, 8))
        cg.setFillColor(color(0xE6E6EA).cgColor)
        cg.fillPath()
        text("docs.example.com/building-a-mac-app", at: CGPoint(x: url.minX + 112, y: url.minY + 6), size: 13, color: color(0x6E6E73))

        let column = window.minX + 250
        text("Shipping your first Mac app", at: CGPoint(x: column, y: window.minY + 110), size: 40, weight: .bold, color: color(0x1D1D1F))
        text("A practical guide, from the first window to the App Store", at: CGPoint(x: column, y: window.minY + 166),
             size: 19, color: color(0x6E6E73))
        var y = window.minY + 230
        let widths: [CGFloat] = [700, 690, 712, 650, 0, 705, 698, 640, 710, 520, 0, 702, 688, 715, 600]
        for width in widths {
            if width > 0 {
                cg.addPath(roundedRect(CGRect(x: column, y: y, width: width, height: 11), 5.5))
                cg.setFillColor(color(0xD9D9DE).cgColor)
                cg.fillPath()
            }
            y += width > 0 ? 26 : 22
        }
        cg.restoreGState()

        // Menu bar: app menus left of the notch, status items right of it.
        cg.setFillColor(color(0xFFFFFF, 0.42).cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: screenSize.width, height: notch.height))
        let ink = color(0x1D1D1F)
        symbol("apple.logo", at: CGRect(x: 20, y: 8, width: 16, height: 16), color: ink)
        var x: CGFloat = 54
        for (i, item) in ["Safari", "File", "Edit", "View", "History"].enumerated() {
            text(item, at: CGPoint(x: x, y: 7), size: 13.5, weight: i == 0 ? .bold : .regular, color: ink)
            x += textWidth(item, size: 13.5, weight: i == 0 ? .bold : .regular) + 20
        }
        let clock = "Wed 9:41 AM"
        let clockX = screenSize.width - 18 - textWidth(clock, size: 13.5)
        text(clock, at: CGPoint(x: clockX, y: 7), size: 13.5, color: ink)
        var statusX = clockX - 34
        for name in ["switch.2", "magnifyingglass", "wifi", "battery.75percent"] {
            symbol(name, at: CGRect(x: statusX, y: 9, width: 20, height: name.hasPrefix("battery") ? 12 : 14), color: ink)
            statusX -= 36
        }

        // The island, as the app drew it: its window is centered under the notch.
        if let island {
            island.draw(in: CGRect(x: (screenSize.width - island.size.width) / 2, y: 0, width: island.size.width, height: island.size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        // The notch itself, with the camera in it.
        let notchRect = CGRect(x: (screenSize.width - notch.width) / 2, y: 0, width: notch.width, height: notch.height)
        let notchPath = CGMutablePath()
        notchPath.move(to: CGPoint(x: notchRect.minX - 6, y: 0))
        notchPath.addQuadCurve(to: CGPoint(x: notchRect.minX, y: 6), control: CGPoint(x: notchRect.minX, y: 0))
        notchPath.addLine(to: CGPoint(x: notchRect.minX, y: notchRect.maxY - 10))
        notchPath.addQuadCurve(to: CGPoint(x: notchRect.minX + 10, y: notchRect.maxY), control: CGPoint(x: notchRect.minX, y: notchRect.maxY))
        notchPath.addLine(to: CGPoint(x: notchRect.maxX - 10, y: notchRect.maxY))
        notchPath.addQuadCurve(to: CGPoint(x: notchRect.maxX, y: notchRect.maxY - 10), control: CGPoint(x: notchRect.maxX, y: notchRect.maxY))
        notchPath.addLine(to: CGPoint(x: notchRect.maxX, y: 6))
        notchPath.addQuadCurve(to: CGPoint(x: notchRect.maxX + 6, y: 0), control: CGPoint(x: notchRect.maxX, y: 0))
        notchPath.closeSubpath()
        cg.addPath(notchPath)
        cg.setFillColor(color(0x000000).cgColor)
        cg.fillPath()
        let lens = CGRect(x: screenSize.width / 2 - 5, y: 11, width: 10, height: 10)
        cg.setFillColor(color(0x15161C).cgColor)
        cg.fillEllipse(in: lens)
        cg.setFillColor(color(0x2B3550).cgColor)
        cg.fillEllipse(in: lens.insetBy(dx: 2.5, dy: 2.5))
        cg.setFillColor(color(0xFFFFFF, 0.35).cgColor)
        cg.fillEllipse(in: CGRect(x: lens.minX + 3, y: lens.minY + 2.5, width: 2, height: 2))
    }
}

// MARK: Laptop

/// A front-on MacBook Pro: black bezel with the notch, aluminium lid edge and base.
func laptop(screen: NSBitmapImageRep, background: (CGContext, CGSize) -> Void) -> NSBitmapImageRep {
    let canvas = CGSize(width: 1800, height: 1200)
    let display = CGSize(width: 1460, height: 1460 * screenSize.height / screenSize.width)
    let bezel: CGFloat = 16
    let lid = CGRect(x: (canvas.width - display.width) / 2 - bezel, y: 92, width: display.width + 2 * bezel, height: display.height + bezel + 22)
    let screenRect = CGRect(x: lid.minX + bezel, y: lid.minY + bezel, width: display.width, height: display.height)
    return render(canvas) { cg in
        background(cg, canvas)

        // Shadow on the "table".
        let shadow = CGGradient(colorsSpace: nil, colors: [color(0x000000, 0.45).cgColor, color(0x000000, 0).cgColor] as CFArray, locations: [0, 1])!
        cg.saveGState()
        cg.translateBy(x: canvas.width / 2, y: lid.maxY + 34)
        cg.scaleBy(x: 1, y: 0.07)
        cg.drawRadialGradient(shadow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: lid.width * 0.62, options: [])
        cg.restoreGState()

        // Lid: aluminium edge, black glass.
        cg.addPath(roundedRect(lid.insetBy(dx: -3, dy: -3), 30))
        cg.setFillColor(color(0x8E9096).cgColor)
        cg.fillPath()
        cg.addPath(roundedRect(lid, 27))
        cg.setFillColor(color(0x050506).cgColor)
        cg.fillPath()
        image(of: screen).draw(in: screenRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        // Screen corners are rounded at the top on these MacBooks.
        cg.saveGState()
        let corner: CGFloat = 12
        let cover = CGMutablePath()
        cover.addRect(screenRect)
        cover.addPath(CGPath(roundedRect: CGRect(x: screenRect.minX, y: screenRect.minY, width: screenRect.width, height: screenRect.height + corner),
                             cornerWidth: corner, cornerHeight: corner, transform: nil))
        cg.addPath(cover)
        cg.setFillColor(color(0x050506).cgColor)
        cg.fillPath(using: .evenOdd)
        cg.restoreGState()

        // Glass reflection.
        cg.saveGState()
        cg.addPath(roundedRect(lid, 27))
        cg.clip()
        let sheen = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF, 0.07).cgColor, color(0xFFFFFF, 0).cgColor] as CFArray, locations: [0, 1])!
        cg.drawLinearGradient(sheen, start: CGPoint(x: lid.minX, y: lid.minY), end: CGPoint(x: lid.midX, y: lid.midY), options: [])
        cg.restoreGState()

        // Base.
        let base = CGRect(x: lid.minX - 46, y: lid.maxY + 2, width: lid.width + 92, height: 26)
        let basePath = CGMutablePath()
        basePath.move(to: CGPoint(x: base.minX, y: base.minY))
        basePath.addLine(to: CGPoint(x: base.maxX, y: base.minY))
        basePath.addQuadCurve(to: CGPoint(x: base.maxX - 30, y: base.maxY), control: CGPoint(x: base.maxX, y: base.maxY))
        basePath.addLine(to: CGPoint(x: base.minX + 30, y: base.maxY))
        basePath.addQuadCurve(to: CGPoint(x: base.minX, y: base.minY), control: CGPoint(x: base.minX, y: base.maxY))
        cg.saveGState()
        cg.addPath(basePath)
        cg.clip()
        let metal = CGGradient(colorsSpace: nil, colors: [color(0xD9DBDF).cgColor, color(0xA9ACB3).cgColor, color(0x6E7178).cgColor] as CFArray,
                               locations: [0, 0.45, 1])!
        cg.drawLinearGradient(metal, start: CGPoint(x: 0, y: base.minY), end: CGPoint(x: 0, y: base.maxY), options: [])
        cg.restoreGState()
        let thumb = CGRect(x: canvas.width / 2 - 110, y: base.minY, width: 220, height: 9)
        cg.addPath(CGPath(roundedRect: thumb, cornerWidth: 9, cornerHeight: 9, transform: nil))
        cg.setFillColor(color(0x8A8D94).cgColor)
        cg.fillPath()
    }
}

func darkBackground(_ cg: CGContext, _ size: CGSize) {
    let gradient = CGGradient(colorsSpace: nil, colors: [color(0x1B1C22).cgColor, color(0x0A0A0D).cgColor] as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(gradient, startCenter: CGPoint(x: size.width / 2, y: size.height * 0.4), startRadius: 0,
                          endCenter: CGPoint(x: size.width / 2, y: size.height * 0.4), endRadius: size.width * 0.75, options: [.drawsAfterEndLocation])
}

func lightBackground(_ cg: CGContext, _ size: CGSize) {
    let gradient = CGGradient(colorsSpace: nil, colors: [color(0xFFFFFF).cgColor, color(0xE9EAEE).cgColor] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
}

// MARK: Close-up

/// The top of the screen around the notch, collapsed next to expanded, with captions.
func closeup(collapsed: NSBitmapImageRep, expanded: NSBitmapImageRep) -> NSBitmapImageRep {
    let crop = CGRect(x: screenSize.width / 2 - 380, y: 0, width: 760, height: 470)
    let gap: CGFloat = 48, margin: CGFloat = 60, caption: CGFloat = 70
    let canvas = CGSize(width: crop.width * 2 + gap + 2 * margin, height: crop.height + 2 * margin + caption)
    return render(canvas) { cg in
        darkBackground(cg, canvas)
        for (i, (rep, title)) in [(collapsed, "Tucked into the notch"), (expanded, "Glance at the camera: it slides out")].enumerated() {
            let frame = CGRect(x: margin + CGFloat(i) * (crop.width + gap), y: margin, width: crop.width, height: crop.height)
            cg.saveGState()
            cg.addPath(roundedRect(frame, 22))
            cg.clip()
            image(of: rep).draw(in: frame, from: CGRect(x: crop.minX, y: screenSize.height - crop.maxY, width: crop.width, height: crop.height),
                                operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            cg.restoreGState()
            text(title, at: CGPoint(x: frame.midX - textWidth(title, size: 26, weight: .semibold) / 2, y: frame.maxY + 24),
                 size: 26, weight: .semibold, color: color(0xF5F5F7))
        }
    }
}

// MARK: Output

let expandedIsland = loadIsland("expand")
let collapsedIsland = loadIsland("collapse") ?? loadIsland("visible-true")
if expandedIsland == nil || collapsedIsland == nil { print("note: island captures missing in \(inputDir.path), drawing without them") }

let expandedScreen = screen(island: expandedIsland)
let collapsedScreen = screen(island: collapsedIsland)
/// A square cut around the notch: multi-image posts show each image roughly square in the feed,
/// and a centered crop of the whole laptop would cut the island off.
func square(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
    let side: CGFloat = 1000
    let crop = CGRect(x: rep.size.width / 2 - side / 2, y: 20, width: side, height: side)
    return render(CGSize(width: side, height: side)) { _ in
        image(of: rep).draw(in: CGRect(x: -crop.minX, y: -crop.minY, width: rep.size.width, height: rep.size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

// A two-image carousel (closed → open), plus square cuts for the feed, a light variant and a close-up.
let closedLaptop = laptop(screen: collapsedScreen, background: darkBackground)
let openLaptop = laptop(screen: expandedScreen, background: darkBackground)
save(closedLaptop, "carousel-1-closed.png")
save(openLaptop, "carousel-2-open.png")
save(square(closedLaptop), "square-1-closed.png")
save(square(openLaptop), "square-2-open.png")
save(laptop(screen: collapsedScreen, background: lightBackground), "light-1-closed.png")
save(laptop(screen: expandedScreen, background: lightBackground), "light-2-open.png")
save(closeup(collapsed: collapsedScreen, expanded: expandedScreen), "notch-closeup.png")
