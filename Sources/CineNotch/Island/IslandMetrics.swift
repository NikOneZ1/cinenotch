import AppKit
import CineNotchGeometry

/// Positions of everything inside the island, in island-local coordinates (origin top-left).
struct IslandLayout: Equatable {
    var size: CGSize
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var video: CGRect
    var videoRadius: CGFloat
    var title: CGRect
    var ring: CGRect
    var progressBar: CGRect
    var controls: CGRect
}

/// How big the video gets when the island opens (Settings → General, the menu, a pinch).
enum IslandVideoSize: String, CaseIterable, Identifiable {
    case small, medium, large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    var bigger: IslandVideoSize? {
        switch self {
        case .small: return .medium
        case .medium: return .large
        case .large: return nil
        }
    }

    var smaller: IslandVideoSize? {
        switch self {
        case .small: return nil
        case .medium: return .small
        case .large: return .medium
        }
    }

    /// The box the video fits into. Large stays clear of the screen's edges on small displays.
    func box(screen: CGRect) -> CGSize {
        switch self {
        case .small: return CGSize(width: 400, height: 285)
        case .medium: return CGSize(width: 560, height: 400)
        case .large: return CGSize(width: min(760, (screen.width * 0.55).rounded()), height: min(540, (screen.height * 0.6).rounded()))
        }
    }
}

/// Screen-dependent geometry: a notch flush with the top edge on notched MacBooks, a pill
/// floating on the camera island where there is one, a pill in the menu bar elsewhere.
struct IslandMetrics: Equatable {
    var screenFrame: CGRect
    var menuBarHeight: CGFloat
    var cutout: CutoutKind
    /// Notch: the camera housing. Island: the pill around the camera (without the gap above
    /// it). nil without a cutout.
    var housing: CGSize?
    /// Island only: from the top edge of the screen to the top of the pill.
    var topGap: CGFloat = 0
    /// Island only: Apple's island while it is expanded. The wings move out beside it and the
    /// open video starts below it. nil while it is idle (or can't be seen).
    var systemIsland: SystemIslandOccupancy?
    var videoSize: IslandVideoSize = .medium
    /// The video fits into this box when the island is expanded.
    var maxVideo: CGSize { videoSize.box(screen: screenFrame) }

    private let pad: CGFloat = 10
    private let wing: CGFloat = 130
    private let pillWidth: CGFloat = 300
    private let controlsHeight: CGFloat = 32
    /// Space kept between Apple's expanded island and ours.
    private let yieldMargin: CGFloat = 6

    var isIsland: Bool { cutout == .island }
    /// Notch and island: the island grows out of the camera housing rather than from a dot.
    var growsFromHousing: Bool { housing != nil }
    var pillHeight: CGFloat { housing?.height ?? max(20, menuBarHeight - 6) }
    /// Gap between the top of the screen and the island.
    var topInset: CGFloat {
        switch cutout {
        case .notch: return 0
        case .island: return topGap
        case .none: return floor((menuBarHeight - pillHeight) / 2)
        }
    }
    /// The middle part the wings go around: the housing, or Apple's expanded island.
    var cutoutWidth: CGFloat {
        guard let housing else { return 0 }
        guard isIsland, let system = systemIsland else { return housing.width }
        return min(max(housing.width, system.width + 2 * yieldMargin), screenFrame.width * 0.7)
    }
    var collapsedWidth: CGFloat { housing == nil ? pillWidth : cutoutWidth + 2 * wing }
    /// Width of the chin that leans out under the camera while a glance builds up.
    var bumpWidth: CGFloat {
        guard let housing else { return 96 }
        // The island's pill is narrow; the chin keeps a usable width under it.
        return isIsland ? min(150, max(48, housing.width)) : min(150, housing.width - 35)
    }
    /// The idle cutout, as the classifier describes it.
    var geometry: CutoutGeometry { CutoutGeometry(kind: cutout, housing: housing, topGap: topGap, reason: "in use") }
    /// Screen-normalized y the eyes aim at to look into the camera (see `GazeMath.cameraY`).
    var cameraY: Double {
        CameraPlacement.normalizedY(classic: GazeMath.cameraY, geometry: geometry,
                                           menuBarHeight: menuBarHeight, screenHeight: screenFrame.height)
    }

    /// Measures every screen, logs them, and classifies the one the island goes on.
    /// `forced` (`--debug-layout`, `--debug-notch`) wins over what the screen reports.
    @MainActor static func current(forced: CutoutKind?, videoSize: IslandVideoSize) -> IslandMetrics {
        let screens = NSScreen.screens
        let measured = screens.map { ScreenMeasurements($0) }
        let kinds = measured.map { CutoutClassifier.classify($0) }
        for (i, screen) in screens.enumerated() {
            Log.info("screen \(i) '\(screen.localizedName)': \(measured[i].summary) -> \(kinds[i].summary)")
        }
        guard let index = CutoutClassifier.preferredScreen(kinds.map(\.kind)) else {
            let frame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            Log.info("no screens; using a plain menu bar pill on \(frame)")
            return IslandMetrics(screenFrame: frame, menuBarHeight: 24, cutout: .none, housing: nil, videoSize: videoSize)
        }
        let m = measured[index]
        var geometry = kinds[index]
        if let forced {
            geometry = CutoutClassifier.forced(forced, measured: geometry, measurements: m)
            Log.info("layout forced to \(forced.rawValue): \(geometry.summary)")
        }
        let metrics = IslandMetrics(measurements: m, geometry: geometry, videoSize: videoSize)
        Log.info("island on screen \(index): \(metrics.summary)")
        return metrics
    }

    init(screenFrame: CGRect, menuBarHeight: CGFloat, cutout: CutoutKind, housing: CGSize?, topGap: CGFloat = 0,
         videoSize: IslandVideoSize = .medium) {
        self.screenFrame = screenFrame
        self.menuBarHeight = menuBarHeight
        self.cutout = cutout
        self.housing = housing
        self.topGap = topGap
        self.videoSize = videoSize
    }

    init(measurements m: ScreenMeasurements, geometry: CutoutGeometry, videoSize: IslandVideoSize) {
        let reserved = m.menuBarReserved
        self.init(screenFrame: m.frame, menuBarHeight: reserved > 10 ? reserved : 24, cutout: geometry.kind,
                  housing: geometry.housing, topGap: geometry.kind == .island ? geometry.topGap : 0, videoSize: videoSize)
    }

    /// What the island will use, for the log.
    var summary: String {
        let size = housing.map { "\($0.width)x\($0.height)" } ?? "nil"
        let system = systemIsland.map { " systemIsland=\($0.width)x\($0.depth) (\($0.source))" } ?? ""
        return "kind=\(cutout.rawValue) housing=\(size) topGap=\(topGap) topInset=\(topInset) pillHeight=\(pillHeight) "
            + "collapsedWidth=\(collapsedWidth) menuBar=\(menuBarHeight) cameraY=\(String(format: "%.4f", cameraY))\(system)"
    }

    func videoSize(aspect: CGFloat) -> CGSize { videoSize(aspect: aspect, box: maxVideo) }

    private func videoSize(aspect: CGFloat, box: CGSize) -> CGSize {
        let a = min(max(aspect, 0.4), 3)
        var width = box.width
        var height = width / a
        if height > box.height {
            height = box.height
            width = height * a
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    func layout(expanded: Bool, aspect: CGFloat) -> IslandLayout {
        expanded ? expandedLayout(aspect: aspect) : collapsedLayout(aspect: aspect)
    }

    /// The island's frame in screen coordinates (bottom-left origin) for a given layout.
    func screenRect(for layout: IslandLayout) -> CGRect {
        CGRect(x: screenFrame.midX - layout.size.width / 2,
               y: screenFrame.maxY - topInset - layout.size.height,
               width: layout.size.width, height: layout.size.height)
    }

    /// A fixed window frame that fits the island in every state and at every video size, plus
    /// room for its shadow and the ambient glow under the video.
    func panelFrame() -> CGRect {
        let margin: CGFloat = 230
        let largest = IslandVideoSize.allCases.map { $0.box(screen: screenFrame) }.max { $0.width * $0.height < $1.width * $1.height }
        let sizes = [0.5, 1, 4.0 / 3, 16.0 / 9, 2.4].map { expandedLayout(aspect: $0, box: largest ?? maxVideo).size }
        let width = (sizes.map(\.width).max() ?? collapsedWidth) + 2 * margin
        let height = topInset + (sizes.map(\.height).max() ?? pillHeight) + margin
        return CGRect(x: (screenFrame.midX - width / 2).rounded(), y: screenFrame.maxY - height,
                      width: width.rounded(), height: height.rounded())
    }

    private func collapsedLayout(aspect: CGFloat) -> IslandLayout {
        let h = pillHeight
        let w = collapsedWidth
        let a = min(max(aspect, 0.6), 1.9)
        let expanded = expandedLayout(aspect: aspect)
        // Controls stay at their expanded size and slide in from under the pill.
        let controls = CGRect(x: (w - expanded.controls.width) / 2, y: h,
                              width: expanded.controls.width, height: expanded.controls.height)

        if housing != nil {
            // The camera splits the pill in two: the title gets the whole left wing,
            // the thumbnail and the ring share the right one. On an island the pill floats
            // below the top edge and is a capsule, so the ends keep clear of the round caps.
            let island = isIsland
            let cap: CGFloat = island ? max(14, h / 2) : 14
            let thumbHeight = island ? max(10, h - 12) : h - 12
            let ring = CGRect(x: w - cap - 16, y: (h - 16) / 2, width: 16, height: 16)
            let thumbWidth = (thumbHeight * a).rounded()
            let thumb = CGRect(x: ring.minX - 8 - thumbWidth, y: (h - thumbHeight) / 2, width: thumbWidth, height: thumbHeight)
            let leftWingEnd = (w - cutoutWidth) / 2
            let titleX: CGFloat = island ? max(16, h / 2) : 16
            let title = CGRect(x: titleX, y: 0, width: max(0, leftWingEnd - 10 - titleX), height: h)
            let bar = CGRect(x: titleX, y: h - 2, width: w - 2 * titleX, height: 2)
            return IslandLayout(size: CGSize(width: w, height: h), topRadius: island ? h / 2 : 0,
                                bottomRadius: island ? h / 2 : min(12, h / 2.5),
                                video: thumb, videoRadius: 4, title: title, ring: ring,
                                progressBar: bar, controls: controls)
        }

        let thumbHeight = h - 6
        let thumb = CGRect(x: 5, y: 3, width: (thumbHeight * a).rounded(), height: thumbHeight)
        let ring = CGRect(x: w - 7 - 14, y: (h - 14) / 2, width: 14, height: 14)
        let title = CGRect(x: thumb.maxX + 8, y: 0, width: max(0, ring.minX - 8 - thumb.maxX - 8), height: h)
        let bar = CGRect(x: title.minX, y: h - 2, width: title.width, height: 2)
        return IslandLayout(size: CGSize(width: w, height: h), topRadius: h / 2, bottomRadius: h / 2,
                            video: thumb, videoRadius: 4, title: title, ring: ring,
                            progressBar: bar, controls: controls)
    }

    private func expandedLayout(aspect: CGFloat, box: CGSize? = nil) -> IslandLayout {
        let v = videoSize(aspect: aspect, box: box ?? maxVideo)
        // The header row sits beside the camera. While Apple's island is expanded it reaches
        // down to below it, so the video doesn't start underneath.
        var header: CGFloat = growsFromHousing ? pillHeight : 32
        if isIsland, let system = systemIsland {
            header = max(header, system.depth - topInset + yieldMargin)
        }
        let w = max(collapsedWidth, v.width + 2 * pad)
        let video = CGRect(x: ((w - v.width) / 2).rounded(), y: header + (growsFromHousing ? 6 : 0),
                           width: v.width, height: v.height)
        let bar = CGRect(x: video.minX + 2, y: video.maxY + 12, width: video.width - 4, height: 4)
        let controls = CGRect(x: video.minX, y: bar.maxY + 6, width: video.width, height: controlsHeight)
        let h = controls.maxY + 8
        let ringSize: CGFloat = 16
        // The camera row is the top `pillHeight` of the header; title and ring stay in it.
        let row = growsFromHousing ? pillHeight : header
        let ring = CGRect(x: w - pad - 6 - ringSize, y: (row - ringSize) / 2, width: ringSize, height: ringSize)
        let titleX = pad + 6
        let titleEnd = housing != nil ? (w - cutoutWidth) / 2 - 10 : ring.minX - 10
        let title = CGRect(x: titleX, y: 0, width: max(0, titleEnd - titleX), height: row)
        let topRadius: CGFloat
        switch cutout {
        case .notch: topRadius = 0
        // Rounded like the collapsed capsule, so the open island doesn't hang a flat edge off the glass.
        case .island: topRadius = min(22, pillHeight / 2)
        case .none: topRadius = 22
        }
        return IslandLayout(size: CGSize(width: w, height: h), topRadius: topRadius,
                            bottomRadius: growsFromHousing ? 28 : 22, video: video, videoRadius: 12,
                            title: title, ring: ring, progressBar: bar, controls: controls)
    }
}

extension ScreenMeasurements {
    /// What AppKit reports for `screen`.
    @MainActor init(_ screen: NSScreen) {
        let insets = screen.safeAreaInsets
        self.init(frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: insets.top, safeAreaLeft: insets.left,
                  safeAreaBottom: insets.bottom, safeAreaRight: insets.right,
                  auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea)
    }
}
