import AppKit

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

/// Screen-dependent geometry: a real notch on notched MacBooks, a pill in the menu bar elsewhere.
struct IslandMetrics: Equatable {
    var screenFrame: CGRect
    var menuBarHeight: CGFloat
    /// Size of the camera housing; nil on displays without a notch.
    var notch: CGSize?
    var videoSize: IslandVideoSize = .medium
    /// The video fits into this box when the island is expanded.
    var maxVideo: CGSize { videoSize.box(screen: screenFrame) }

    private let pad: CGFloat = 10
    private let wing: CGFloat = 130
    private let pillWidth: CGFloat = 300
    private let controlsHeight: CGFloat = 32

    var hasNotch: Bool { notch != nil }
    var pillHeight: CGFloat { notch?.height ?? max(20, menuBarHeight - 6) }
    /// Gap between the top of the screen and the island.
    var topInset: CGFloat { hasNotch ? 0 : floor((menuBarHeight - pillHeight) / 2) }
    var collapsedWidth: CGFloat { notch.map { $0.width + 2 * wing } ?? pillWidth }
    /// Width of the chin that leans out under the camera while a glance builds up.
    var bumpWidth: CGFloat { notch.map { min(150, $0.width - 35) } ?? 96 }

    @MainActor static func current(debugNotch: Bool, videoSize: IslandVideoSize) -> IslandMetrics {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first ?? NSScreen.main!
        let frame = screen.frame
        let reserved = frame.maxY - screen.visibleFrame.maxY
        let menuBar = reserved > 10 ? reserved : 24
        var notch: CGSize?
        if screen.safeAreaInsets.top > 0 {
            let left = screen.auxiliaryTopLeftArea?.width ?? 0
            let right = screen.auxiliaryTopRightArea?.width ?? 0
            notch = CGSize(width: frame.width - left - right, height: screen.safeAreaInsets.top)
        } else if debugNotch {
            notch = CGSize(width: 185, height: 32)
        }
        return IslandMetrics(screenFrame: frame, menuBarHeight: menuBar, notch: notch, videoSize: videoSize)
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

        if let notch {
            // The camera splits the pill in two: the title gets the whole left wing,
            // the thumbnail and the ring share the right one.
            let thumbHeight = h - 12
            let ring = CGRect(x: w - 14 - 16, y: (h - 16) / 2, width: 16, height: 16)
            let thumbWidth = (thumbHeight * a).rounded()
            let thumb = CGRect(x: ring.minX - 8 - thumbWidth, y: 6, width: thumbWidth, height: thumbHeight)
            let leftWingEnd = (w - notch.width) / 2
            let title = CGRect(x: 16, y: 0, width: max(0, leftWingEnd - 10 - 16), height: h)
            let bar = CGRect(x: 16, y: h - 2, width: w - 32, height: 2)
            return IslandLayout(size: CGSize(width: w, height: h), topRadius: 0, bottomRadius: min(12, h / 2.5),
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
        let header: CGFloat = hasNotch ? pillHeight : 32
        let w = max(collapsedWidth, v.width + 2 * pad)
        let video = CGRect(x: ((w - v.width) / 2).rounded(), y: header + (hasNotch ? 6 : 0),
                           width: v.width, height: v.height)
        let bar = CGRect(x: video.minX + 2, y: video.maxY + 12, width: video.width - 4, height: 4)
        let controls = CGRect(x: video.minX, y: bar.maxY + 6, width: video.width, height: controlsHeight)
        let h = controls.maxY + 8
        let ringSize: CGFloat = 16
        let ring = CGRect(x: w - pad - 6 - ringSize, y: (header - ringSize) / 2, width: ringSize, height: ringSize)
        let titleX = pad + 6
        let titleEnd = notch.map { (w - $0.width) / 2 - 10 } ?? ring.minX - 10
        let title = CGRect(x: titleX, y: 0, width: max(0, titleEnd - titleX), height: header)
        return IslandLayout(size: CGSize(width: w, height: h), topRadius: hasNotch ? 0 : 22,
                            bottomRadius: hasNotch ? 28 : 22, video: video, videoRadius: 12,
                            title: title, ring: ring, progressBar: bar, controls: controls)
    }
}
