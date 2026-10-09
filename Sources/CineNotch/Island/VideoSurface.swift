import AppKit
import CoreImage
import SwiftUI

/// Hands captured frames straight to the video layer, bypassing SwiftUI updates.
@MainActor
final class FrameSink {
    private weak var view: VideoSurfaceNSView?
    private(set) var last: IOSurface?
    /// Also gets every frame, e.g. the ambient glow.
    var observer: ((IOSurface) -> Void)?

    func push(_ surface: IOSurface) {
        last = surface
        view?.show(surface)
        observer?(surface)
    }

    func clear() {
        last = nil
        view?.show(nil)
    }

    /// The latest frame as an image, for the menu.
    func snapshot() -> CGImage? {
        guard let last else { return nil }
        let image = CIImage(ioSurface: last)
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(image, from: image.extent)
    }

    fileprivate func attach(_ view: VideoSurfaceNSView) {
        self.view = view
        view.show(last)
    }
}

final class VideoSurfaceNSView: NSView {
    private var desaturation = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        let layer = CALayer()
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        // Every change is driven frame by frame by IslandMotion; no implicit animations.
        layer.actions = ["contents": NSNull(), "cornerRadius": NSNull(), "filters": NSNull(),
                         "bounds": NSNull(), "position": NSNull()]
        self.layer = layer
        wantsLayer = true
        layerUsesCoreImageFilters = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ surface: IOSurface?) {
        layer?.contents = surface
    }

    func setCornerRadius(_ radius: CGFloat) {
        guard let layer, layer.cornerRadius != radius else { return }
        layer.cornerRadius = radius
    }

    /// 0 = full color, 1 = the washed-out thumbnail of a paused video.
    func setDesaturation(_ amount: Double) {
        let amount = (min(max(amount, 0), 1) * 50).rounded() / 50
        guard amount != desaturation, let layer else { return }
        desaturation = amount
        if amount == 0 {
            layer.filters = nil
        } else {
            let filter = CIFilter(name: "CIColorControls")
            filter?.setValue(1 - 0.85 * amount, forKey: kCIInputSaturationKey)
            filter?.setValue(-0.12 * amount, forKey: kCIInputBrightnessKey)
            layer.filters = filter.map { [$0] }
        }
    }

    // Clicks go to the SwiftUI overlay above the video.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct VideoSurface: NSViewRepresentable {
    let sink: FrameSink
    var cornerRadius: CGFloat
    var desaturation: Double = 0

    func makeNSView(context: Context) -> VideoSurfaceNSView {
        let view = VideoSurfaceNSView(frame: .zero)
        sink.attach(view)
        return view
    }

    func updateNSView(_ view: VideoSurfaceNSView, context: Context) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.setCornerRadius(cornerRadius)
        view.setDesaturation(desaturation)
        CATransaction.commit()
    }
}
