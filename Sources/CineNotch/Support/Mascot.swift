import AppKit
import SwiftUI

/// The mascot's eyes: two glowing lime ovals. `openness` 0 is shut, 1 wide open.
/// Round and set apart on purpose: two tall bars side by side read as a pause button.
struct MascotEyes: View {
    var openness: Double = 1
    var eyeSize = CGSize(width: 7, height: 10)
    var spacing: CGFloat = 13
    /// Sideways glance in points.
    var look: CGFloat = 0

    var body: some View {
        HStack(spacing: spacing) {
            eye
            eye
        }
        .offset(x: look)
        .scaleEffect(x: 1, y: max(0.001, openness), anchor: .center)
    }

    private var eye: some View {
        Ellipse()
            .fill(Theme.accent)
            .frame(width: eyeSize.width, height: eyeSize.height)
            .shadow(color: Theme.accent.opacity(0.75), radius: eyeSize.width * 0.6)
            .overlay(alignment: .topLeading) {
                // A catchlight, once the eyes are big enough to show one.
                if eyeSize.width >= 9 {
                    Circle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: eyeSize.width * 0.3, height: eyeSize.width * 0.3)
                        .offset(x: eyeSize.width * 0.2, y: eyeSize.height * 0.15)
                }
            }
    }
}

/// The mascot: a black island with eyes. Blinks and looks around on its own.
struct Mascot: View {
    var width: CGFloat = 70
    var awake = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !awake)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let scale = width / 70
            Capsule()
                .fill(Theme.ink)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
                .frame(width: width, height: width * 0.46)
                .overlay(
                    MascotEyes(openness: awake ? Self.blink(t) : 0.12,
                               eyeSize: CGSize(width: 7.5 * scale, height: 11 * scale),
                               spacing: 13 * scale,
                            look: awake ? Self.look(t) * scale : 0)
                )
        }
        .accessibilityHidden(true)
    }

    /// A quick blink every 4.4 s.
    static func blink(_ t: Double) -> Double {
        let phase = t.truncatingRemainder(dividingBy: 4.4) / 4.4
        guard phase > 0.9, phase < 0.97 else { return 1 }
        return 0.1 + 0.9 * abs(phase - 0.935) / 0.035
    }

    /// Glances right, then left, every 7 s.
    static func look(_ t: Double) -> CGFloat {
        let phase = t.truncatingRemainder(dividingBy: 7) / 7
        func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
        switch phase {
        case ..<0.35: return 0
        case ..<0.45: return CGFloat(3 * ease((phase - 0.35) / 0.1))
        case ..<0.62: return 3
        case ..<0.72: return CGFloat(3 - 5 * ease((phase - 0.62) / 0.1))
        case ..<0.9: return -2
        default: return CGFloat(-2 + 2 * ease((phase - 0.9) / 0.1))
        }
    }
}

/// The menu bar icon: the mascot's outline, filled in while a video is docked.
enum StatusIcon {
    static func image(active: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            let body = NSRect(x: 1.5, y: 3.5, width: 19, height: 9)
            let capsule = NSBezierPath(roundedRect: body, xRadius: 4.5, yRadius: 4.5)
            let eyes = [NSRect(x: 6.9, y: 6.1, width: 2.8, height: 3.8), NSRect(x: 12.3, y: 6.1, width: 2.8, height: 3.8)]
                .map { NSBezierPath(ovalIn: $0) }
            NSColor.black.setFill()
            NSColor.black.setStroke()
            if active {
                // Eyes cut out of a filled body.
                let path = capsule.copy() as! NSBezierPath
                eyes.forEach { path.append($0) }
                path.windingRule = .evenOdd
                path.fill()
            } else {
                capsule.lineWidth = 1.4
                capsule.stroke()
                eyes.forEach { $0.fill() }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CineNotch"
        return image
    }
}
