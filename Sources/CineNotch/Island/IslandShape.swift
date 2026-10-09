import SwiftUI

/// A rectangle with separate top and bottom corner radii, so the same shape can be a capsule
/// in the menu bar or hang flat from the notch with rounded bottom corners. A "chin" can bulge
/// out of the middle of the bottom edge: the island leaning out while a glance builds up.
struct IslandShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    /// How far the chin hangs below the bottom edge.
    var bump: CGFloat = 0
    var bumpWidth: CGFloat = 0

    /// Lets SwiftUI animate the shape (the onboarding demo); the island itself is driven by IslandMotion.
    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(topRadius, bottomRadius), bump) }
        set {
            topRadius = newValue.first.first
            bottomRadius = newValue.first.second
            bump = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let t = min(max(topRadius, 0), limit)
        let b = min(max(bottomRadius, 0), limit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + t, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + t), radius: t)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - b, y: rect.maxY), radius: b)
        addChin(to: &path, rect: rect, bottomRadius: b)
        path.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - b), radius: b)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + t))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + t, y: rect.minY), radius: t)
        path.closeSubpath()
        return path
    }

    /// Walks the bottom edge right to left: a concave fillet down, a rounded chin, a fillet back up.
    private func addChin(to path: inout Path, rect: CGRect, bottomRadius b: CGFloat) {
        guard bump > 0.4 else { return }
        let fillet = min(9, bump * 0.45), corner = min(16, bump * 0.55)
        let half = min(bumpWidth / 2, rect.width / 2 - b - fillet - 1)
        guard half > corner + 2 else { return }
        let x = rect.midX, y = rect.maxY, bottom = y + bump
        path.addLine(to: CGPoint(x: x + half + fillet, y: y))
        path.addQuadCurve(to: CGPoint(x: x + half, y: y + fillet), control: CGPoint(x: x + half, y: y))
        path.addLine(to: CGPoint(x: x + half, y: bottom - corner))
        path.addArc(tangent1End: CGPoint(x: x + half, y: bottom), tangent2End: CGPoint(x: x + half - corner, y: bottom), radius: corner)
        path.addLine(to: CGPoint(x: x - half + corner, y: bottom))
        path.addArc(tangent1End: CGPoint(x: x - half, y: bottom), tangent2End: CGPoint(x: x - half, y: bottom - corner), radius: corner)
        path.addLine(to: CGPoint(x: x - half, y: y + fillet))
        path.addQuadCurve(to: CGPoint(x: x - half - fillet, y: y), control: CGPoint(x: x - half, y: y))
    }
}

/// A shape drawn at a fixed place, whatever frame it is given: the island inside its window.
struct PlacedShape<Base: Shape>: Shape {
    var base: Base
    var frame: CGRect

    func path(in rect: CGRect) -> Path { base.path(in: frame) }
}
