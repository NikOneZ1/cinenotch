import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

// Camera cutout classification, kept free of AppKit so it can be unit-tested anywhere.
// `IslandMetrics.current` in the app reads `NSScreen` into `ScreenMeasurements` and calls
// `CutoutClassifier.classify`.
//
// Apple has not published the cutout size or the `safeAreaInsets` values of the MacBook Pro
// with PROLED XDR Display (the one with a camera island). Nothing here is tuned to a measured
// PROLED machine; the thresholds are ratios that separate today's notched Macs from a compact
// or floating housing. Measure real hardware with the screen log before trusting them.

/// What sits at the top center of a screen.
public enum CutoutKind: String, CaseIterable, Sendable {
    /// A housing attached to the top edge, as on notched MacBooks since 2021.
    case notch
    /// A compact camera housing that floats below the top edge (a camera pill / island).
    case island
    /// No housing: the island is a pill in the menu bar.
    case none
}

/// What `NSScreen` reports about one screen, in points. Rects use AppKit screen coordinates;
/// the classifier only reads sizes, so it doesn't matter whose origin they use.
public struct ScreenMeasurements: Equatable, Sendable {
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var safeAreaTop: CGFloat
    public var safeAreaLeft: CGFloat
    public var safeAreaBottom: CGFloat
    public var safeAreaRight: CGFloat
    public var auxiliaryTopLeft: CGRect?
    public var auxiliaryTopRight: CGRect?

    public init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat, safeAreaLeft: CGFloat = 0,
                safeAreaBottom: CGFloat = 0, safeAreaRight: CGFloat = 0,
                auxiliaryTopLeft: CGRect? = nil, auxiliaryTopRight: CGRect? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.safeAreaLeft = safeAreaLeft
        self.safeAreaBottom = safeAreaBottom
        self.safeAreaRight = safeAreaRight
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
    }

    /// The strip above the visible frame: the menu bar (0 while it hides itself).
    public var menuBarReserved: CGFloat { max(0, frame.maxY - visibleFrame.maxY) }

    /// Width between the two auxiliary areas: the housing, when both exist and leave a
    /// plausible gap in the middle.
    public var auxiliaryGapWidth: CGFloat? {
        guard let left = auxiliaryTopLeft, let right = auxiliaryTopRight else { return nil }
        let gap = frame.width - left.width - right.width
        guard gap >= CutoutClassifier.minHousingWidth, gap <= frame.width * CutoutClassifier.maxHousingFraction else { return nil }
        return gap
    }

    /// Height of the auxiliary areas (on notched Macs, the notch height).
    public var auxiliaryHeight: CGFloat? {
        let heights = [auxiliaryTopLeft?.height, auxiliaryTopRight?.height].compactMap { $0 }.filter { $0 > 0 }
        return heights.max()
    }

    public var summary: String {
        func r(_ rect: CGRect?) -> String {
            guard let rect else { return "nil" }
            return "(\(f(rect.minX)), \(f(rect.minY)), \(f(rect.width))x\(f(rect.height)))"
        }
        return "frame=\(r(frame)) visible=\(r(visibleFrame)) "
            + "safeArea(t=\(f(safeAreaTop)) l=\(f(safeAreaLeft)) b=\(f(safeAreaBottom)) r=\(f(safeAreaRight))) "
            + "auxLeft=\(r(auxiliaryTopLeft)) auxRight=\(r(auxiliaryTopRight)) menuBarReserved=\(f(menuBarReserved))"
    }
}

/// Where the top gap of an island came from.
public enum GapSource: String, Sendable {
    /// Not an island: the housing is flush with the top edge (or there is none).
    case none
    /// `safeAreaInsets.top` is the gap above the pill.
    case inset
    /// Nothing measures the gap; a share of the housing depth stands in (see `assumedGapFraction`).
    case assumed
    /// A `--debug-layout` fixture.
    case debug
}

/// The classifier's answer for one screen.
public struct CutoutGeometry: Equatable, Sendable {
    public var kind: CutoutKind
    /// Notch: the housing (width x inset). Island: the pill around the camera (width x pill
    /// height, without the gap above it). nil without a cutout.
    public var housing: CGSize?
    /// Island only: from the top edge of the screen to the top of the pill.
    public var topGap: CGFloat
    public var gapSource: GapSource
    /// True when the housing width had no measurement behind it (no auxiliary areas).
    public var widthAssumed: Bool
    /// Which rule decided, for the log.
    public var reason: String

    public init(kind: CutoutKind, housing: CGSize?, topGap: CGFloat = 0, gapSource: GapSource = .none,
                widthAssumed: Bool = false, reason: String) {
        self.kind = kind
        self.housing = housing
        self.topGap = topGap
        self.gapSource = gapSource
        self.widthAssumed = widthAssumed
        self.reason = reason
    }

    /// From the top edge to the bottom of the housing.
    public var depth: CGFloat { topGap + (housing?.height ?? 0) }

    public var summary: String {
        let size = housing.map { "\(f($0.width))x\(f($0.height))" } ?? "nil"
        return "kind=\(kind.rawValue) housing=\(size) topGap=\(f(topGap)) gap=\(gapSource.rawValue)"
            + (widthAssumed ? " width=assumed" : "") + " (\(reason))"
    }
}

public enum CutoutClassifier {
    /// Insets below this are rounding noise, not a cutout.
    public static let negligibleInset: CGFloat = 0.5
    /// A central gap between the auxiliary areas narrower than this is not a housing.
    public static let minHousingWidth: CGFloat = 8
    /// Nor is one wider than this share of the screen.
    public static let maxHousingFraction: CGFloat = 0.5
    /// A top inset below this share of the menu bar strip is a gap above a floating housing.
    /// On notched Macs the inset is about the menu bar's height (ratio near 1).
    public static let gapLikeRatio: CGFloat = 0.5
    /// A housing narrower than this share of the screen is compact (camera pill). Notched
    /// MacBooks measure about 0.11 to 0.13 at every scaling, since the notch and the screen
    /// scale together. A third-party report for a 16-inch PROLED machine gives a camera slot
    /// of about 59 of 1,736 points (0.034); that is a reported example, not an Apple figure.
    public static let compactWidthFraction: CGFloat = 0.07
    /// When nothing measures the gap above a pill, it is taken as this share of the housing
    /// depth. A placeholder until PROLED hardware is measured, logged as `assumed`.
    public static let assumedGapFraction: CGFloat = 0.2
    /// The smallest pill height the layout accepts.
    public static let minPillHeight: CGFloat = 16
    /// Housing used when a notch has no auxiliary areas (no shipped Mac does this), and by
    /// `--debug-layout notch` on a screen without a notch. Same as the old `--debug-notch`.
    public static let fallbackNotch = CGSize(width: 185, height: 32)

    /// Classic notch, camera island or none, from one screen's measurements.
    ///
    /// Signals:
    /// - Housing width: the gap the auxiliary areas leave in the middle (as before).
    /// - Gap-like inset: a top inset well below the menu bar strip means the inset only covers
    ///   the space above a housing that floats lower in the glass.
    /// - Compact housing: a housing that is a small share of the screen width is a camera
    ///   pill, even when the inset covers it completely.
    /// - No inset but a central housing between the auxiliary areas: an island, not the menu
    ///   bar pill, so the island isn't drawn over the camera.
    /// Anything that looks like a notched Mac today stays a classic notch.
    public static func classify(_ m: ScreenMeasurements) -> CutoutGeometry {
        let inset = m.safeAreaTop
        let auxWidth = m.auxiliaryGapWidth
        let reference = referenceDepth(m)

        if inset < negligibleInset {
            guard let width = auxWidth else {
                return CutoutGeometry(kind: .none, housing: nil, reason: "no top inset, no central housing")
            }
            // The housing shows only through the auxiliary areas. Its depth is their height,
            // or the menu bar strip; the gap isn't measured.
            let depth = m.auxiliaryHeight ?? reference ?? fallbackNotch.height
            return island(width: width, depth: depth,
                          reason: "no top inset but the auxiliary areas leave a \(f(width)) pt housing")
        }

        let gapLike = reference.map { inset < $0 * gapLikeRatio } ?? false
        let compact = auxWidth.map { $0 < m.frame.width * compactWidthFraction } ?? false

        if gapLike, let reference {
            // The inset is the gap; the pill reaches down to the bottom of the reference strip,
            // or to the bottom of the auxiliary areas when those are taller than the inset.
            let bottom = max(reference, m.auxiliaryHeight ?? 0)
            let pill = max(minPillHeight, bottom - inset)
            let width = auxWidth ?? assumedWidth(pillHeight: pill)
            return CutoutGeometry(kind: .island, housing: CGSize(width: width, height: pill), topGap: inset,
                                  gapSource: .inset, widthAssumed: auxWidth == nil,
                                  reason: "top inset \(f(inset)) is under \(f(gapLikeRatio)) of the \(f(reference)) pt strip")
        }
        if compact, let width = auxWidth {
            return island(width: width, depth: inset,
                          reason: "housing \(f(width)) pt is under \(f(compactWidthFraction)) of the screen width")
        }
        guard let width = auxWidth else {
            return CutoutGeometry(kind: .notch, housing: CGSize(width: fallbackNotch.width, height: inset), widthAssumed: true,
                                  reason: "top inset \(f(inset)) without auxiliary areas")
        }
        return CutoutGeometry(kind: .notch, housing: CGSize(width: width, height: inset),
                              reason: "top-attached housing \(f(width))x\(f(inset))")
    }

    /// What `--debug-layout` asks for, on top of what the screen reports.
    public static func forced(_ kind: CutoutKind, measured: CutoutGeometry, measurements m: ScreenMeasurements) -> CutoutGeometry {
        guard measured.kind != kind else { return measured }
        switch kind {
        case .notch:
            return CutoutGeometry(kind: .notch, housing: fallbackNotch, reason: "forced notch, debug housing")
        case .none:
            return CutoutGeometry(kind: .none, housing: nil, reason: "forced menu bar pill")
        case .island:
            // A synthetic pill in the menu bar strip: the assumed share of it as the gap, the
            // rest as the pill, twice as wide as tall. Not a measurement of any Mac.
            let depth = referenceDepth(m) ?? 24
            let gap = (depth * assumedGapFraction).rounded()
            let pill = max(minPillHeight, depth - gap)
            return CutoutGeometry(kind: .island, housing: CGSize(width: assumedWidth(pillHeight: pill), height: pill),
                                  topGap: gap, gapSource: .debug, widthAssumed: true,
                                  reason: "forced island, synthetic housing from the \(f(depth)) pt strip")
        }
    }

    /// The menu bar strip, or the auxiliary areas' height while the menu bar hides itself.
    static func referenceDepth(_ m: ScreenMeasurements) -> CGFloat? {
        if m.menuBarReserved > 10 { return m.menuBarReserved }
        return m.auxiliaryHeight
    }

    /// An island whose gap isn't measured: `depth` covers gap and pill.
    private static func island(width: CGFloat, depth: CGFloat, reason: String) -> CutoutGeometry {
        let gap = (depth * assumedGapFraction).rounded()
        let pill = max(minPillHeight, depth - gap)
        return CutoutGeometry(kind: .island, housing: CGSize(width: width, height: pill), topGap: gap,
                              gapSource: .assumed, reason: reason)
    }

    /// A pill without a measured width: a capsule twice as wide as tall. A guess, logged as such.
    static func assumedWidth(pillHeight: CGFloat) -> CGFloat { (pillHeight * 2).rounded() }

    /// The screen to put the island on: the first with a cutout, else the first.
    public static func preferredScreen(_ kinds: [CutoutKind]) -> Int? {
        kinds.firstIndex { $0 != CutoutKind.none } ?? (kinds.isEmpty ? nil : 0)
    }
}

// MARK: Apple's expanded island

/// One entry of the window list, as `CGWindowListCopyWindowInfo` reports it.
public struct WindowSample: Equatable, Sendable {
    /// Global coordinates, origin at the top-left of the primary display, y down.
    public var bounds: CGRect
    public var layer: Int
    public var ownerPID: Int32
    /// Advisory: logged, never required to match.
    public var ownerName: String?

    public init(bounds: CGRect, layer: Int, ownerPID: Int32, ownerName: String? = nil) {
        self.bounds = bounds
        self.layer = layer
        self.ownerPID = ownerPID
        self.ownerName = ownerName
    }
}

/// What Apple's expanded island takes at the top center: width, and depth from the top edge.
public struct SystemIslandOccupancy: Equatable, Sendable {
    public var width: CGFloat
    public var depth: CGFloat
    /// The window that showed it, for the log. nil when it came from the auxiliary areas.
    public var source: String

    public init(width: CGFloat, depth: CGFloat, source: String) {
        self.width = width
        self.depth = depth
        self.source = source
    }
}

/// Best-effort detection of Apple's island while it is expanded (Spotlight, Live Activities,
/// Siri, privacy indicators). There is no public API for it; this only looks at what anyone
/// can see: windows that sit in the top-center strip above normal windows, and the auxiliary
/// areas leaving a wider gap than the idle housing. Unverified on PROLED hardware: Apple may
/// draw its island in a way neither of these sees, or something else may match.
public enum SystemIslandDetector {
    /// How far off center a window may be and still count, as a share of its width.
    public static let centerTolerance: CGFloat = 0.06
    /// Wider than the idle housing by at least this much.
    public static let minGrowth: CGFloat = 4
    /// At most this share of the screen width or height (larger is not an island).
    public static let maxWidthFraction: CGFloat = 0.7
    public static let maxHeightFraction: CGFloat = 0.5

    /// Geometry only, no process names: a window of another process, above normal windows,
    /// starting inside the top strip (normal windows can't go there), centered on the screen,
    /// wider than the idle housing but not screen-wide.
    /// - Parameters:
    ///   - screen: the screen in the same coordinates as the window bounds.
    ///   - strip: depth of the top strip (menu bar, or the island's depth if taller).
    public static func occupancy(windows: [WindowSample], screen: CGRect, strip: CGFloat,
                                 idleHousingWidth: CGFloat, ownPID: Int32) -> SystemIslandOccupancy? {
        var best: SystemIslandOccupancy?
        for window in windows where window.ownerPID != ownPID && window.layer > 0 {
            let b = window.bounds
            guard b.minY >= screen.minY - 1, b.minY - screen.minY < strip - 1,
                  abs(b.midX - screen.midX) <= max(2, b.width * centerTolerance),
                  b.width >= idleHousingWidth + minGrowth,
                  b.width <= screen.width * maxWidthFraction,
                  b.height <= screen.height * maxHeightFraction else { continue }
            let depth = b.maxY - screen.minY
            if best == nil || b.width > best!.width {
                best = SystemIslandOccupancy(width: b.width, depth: max(depth, best?.depth ?? 0),
                                             source: "window \(window.ownerName ?? "pid \(window.ownerPID)") layer \(window.layer)")
            }
        }
        return best
    }

    /// The auxiliary areas leave a wider gap than the idle housing: the system took more room.
    public static func occupancy(idle: CutoutGeometry, current m: ScreenMeasurements) -> SystemIslandOccupancy? {
        guard idle.kind == .island, let housing = idle.housing, let width = m.auxiliaryGapWidth,
              width >= housing.width + minGrowth else { return nil }
        let depth = max(idle.depth, m.safeAreaTop, m.auxiliaryHeight ?? 0)
        return SystemIslandOccupancy(width: width, depth: depth, source: "auxiliary areas")
    }

    /// The larger of two occupancies.
    public static func merge(_ a: SystemIslandOccupancy?, _ b: SystemIslandOccupancy?) -> SystemIslandOccupancy? {
        guard let a else { return b }
        guard let b else { return a }
        return SystemIslandOccupancy(width: max(a.width, b.width), depth: max(a.depth, b.depth),
                                     source: a.width >= b.width ? a.source : b.source)
    }
}

// MARK: Camera position for glance

public enum CameraPlacement {
    /// Screen-normalized y (0 = top edge, screen heights, y down) the eyes aim at to look into
    /// the camera. `classic` is the value tuned on notched and notch-less Macs (lens just above
    /// the content). On an island the lens sits lower in the glass: the result moves by how
    /// much deeper the lens is than the middle of the menu bar strip. Untested on PROLED hardware.
    public static func normalizedY(classic: Double, geometry: CutoutGeometry, menuBarHeight: CGFloat,
                                   screenHeight: CGFloat) -> Double {
        guard geometry.kind == .island, let housing = geometry.housing, screenHeight > 0 else { return classic }
        let lens = geometry.topGap + housing.height / 2
        return classic + Double((lens - menuBarHeight / 2) / screenHeight)
    }
}

/// Points with at most one decimal, for the log.
private func f(_ value: CGFloat) -> String {
    let rounded = (value * 10).rounded() / 10
    return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", Double(rounded))
}
