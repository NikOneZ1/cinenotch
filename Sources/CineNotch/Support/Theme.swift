import AppKit
import SwiftUI

/// CineNotch's look: a black island, the mascot's phosphor-lime eyes, warm paper windows.
enum Theme {
    /// The mascot's eyes and the one accent everywhere. Fill only: lime text on a light background
    /// doesn't read, so text on it is `onAccent`.
    static let accent = Color(red: 0xC6 / 255, green: 0xF4 / 255, blue: 0x32 / 255)
    static let accentNS = NSColor(srgbRed: 0xC6 / 255, green: 0xF4 / 255, blue: 0x32 / 255, alpha: 1)
    static let onAccent = Color(red: 0x18 / 255, green: 0x22 / 255, blue: 0x0A / 255)
    static let ink = Color(red: 0x0B / 255, green: 0x0B / 255, blue: 0x0A / 255)

    /// Window backgrounds: warm paper in light mode, warm near-black in dark mode.
    static let paper = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x16 / 255, green: 0x17 / 255, blue: 0x14 / 255, alpha: 1)
            : NSColor(srgbRed: 0xF3 / 255, green: 0xF1 / 255, blue: 0xEA / 255, alpha: 1)
    })
    /// Cards on `paper`.
    static let card = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x20 / 255, green: 0x21 / 255, blue: 0x1D / 255, alpha: 1)
            : NSColor.white
    })
    static let hairline = Color(NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.09)
            : NSColor(white: 0, alpha: 0.09)
    })

    static func display(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

/// The main call to action: lime pill with dark text.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.accent))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A quiet pill next to `AccentButtonStyle`.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.hairline))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
