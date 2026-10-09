import AVFoundation
import AppKit
import SwiftUI

/// Debug panel: camera preview, live class probabilities and raw features.
/// While it is open, frames are also logged to ~/Library/Logs/CineNotch-gaze.csv.
@MainActor
final class GazeHUD: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let gaze: GazeController

    init(gaze: GazeController) {
        self.gaze = gaze
    }

    func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 400),
                                styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.title = "Gaze"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: GazeHUDView(gaze: gaze))
            panel.delegate = self
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.minX + 20, y: screen.minY + 20))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        gaze.isHUDVisible = false
    }
}

private struct GazeHUDView: View {
    @ObservedObject var gaze: GazeController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CameraPreview(session: gaze.camera.session)
                .frame(width: 256, height: 144)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(status)
                .font(.system(size: 12, weight: .semibold))

            GazeMap(gaze: gaze)
                .frame(width: 256, height: 176)

            if let features = gaze.features {
                VStack(alignment: .leading, spacing: 2) {
                    row("openness", features.openness)
                    ForEach(gaze.engineIDs.filter { gaze.outputs[$0]?.drift != nil }, id: \.self) { id in
                        let output = gaze.outputs[id]!
                        row("\(id) drift x (\(output.driftAnchors) clicks)", Double(output.drift!.x))
                        row("\(id) drift y", Double(output.drift!.y))
                    }
                    ForEach(Array(zip(GazeFeatures.headNames, features.head)), id: \.0) { name, value in
                        row(name, value)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private func row(_ name: String, _ value: Double) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(String(format: "%+.3f", value)).monospacedDigit()
        }
    }

    private var status: String {
        if !gaze.isCameraRunning { return "Camera off" }
        if gaze.features == nil { return "No face" }
        if !gaze.isCalibrated { return "Face found · not calibrated" }
        let active = gaze.outputs[gaze.activeEngineID]
        if active?.isBlinking == true { return "Blink" }
        if active?.isGlitch == true { return "Landmark glitch, frame dropped" }
        let zone = active?.zone.map { "looking at: \($0.rawValue)" } ?? ""
        if !gaze.isEnabled { return "Gaze reveal is off · \(zone)" }
        return (gaze.wantsExpanded ? "Revealed · " : "Watching · ") + zone
    }
}

/// Distinct colors per engine version, oldest first.
private func engineColor(_ id: String) -> Color {
    let palette: [Color] = [.red, .orange, .purple, .cyan, .pink, .mint]
    let index = GazeController.engineTypes.firstIndex { $0.id == id } ?? 0
    return palette[index % palette.count]
}

/// The screen in miniature: the active engine's camera zone (green) and the island (blue),
/// and every engine's gaze point in its own color.
private struct GazeMap: View {
    @ObservedObject var gaze: GazeController
    /// Normalized y shown at the top of the map; leaves room for the camera above the screen.
    private let top = -0.12

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                func point(_ p: CGPoint) -> CGPoint {
                    CGPoint(x: p.x * size.width, y: (p.y - top) / (1 - top) * size.height)
                }
                func rect(_ r: CGRect) -> CGRect {
                    let a = point(r.origin), b = point(CGPoint(x: r.maxX, y: r.maxY))
                    return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
                }
                let active = gaze.outputs[gaze.activeEngineID]
                let screen = rect(CGRect(x: 0, y: 0, width: 1, height: 1))
                context.fill(Path(screen), with: .color(.secondary.opacity(0.12)))
                context.stroke(Path(screen), with: .color(.secondary.opacity(0.5)))

                let cameraMaxY = gaze.activeReport?.cameraMaxY ?? 0
                let cameraZone = rect(CGRect(x: 0.5 - GazeMath.cameraHalfWidth, y: top,
                                             width: 2 * GazeMath.cameraHalfWidth, height: cameraMaxY - top))
                context.fill(Path(cameraZone), with: .color(.green.opacity(active?.zone == .camera ? 0.45 : 0.18)))
                let lens = point(CGPoint(x: 0.5, y: GazeMath.cameraY))
                context.fill(Path(ellipseIn: CGRect(x: lens.x - 3, y: lens.y - 3, width: 6, height: 6)), with: .color(.green))

                let island = rect(gaze.islandRect().insetBy(dx: -GazeMath.islandMargin, dy: -GazeMath.islandMargin))
                context.stroke(Path(roundedRect: island, cornerRadius: 6),
                               with: .color(.blue.opacity(active?.zone == .video ? 1 : 0.5)), lineWidth: active?.zone == .video ? 2 : 1)

                for id in gaze.engineIDs.reversed() {
                    guard let output = gaze.outputs[id], let gazePoint = output.point else { continue }
                    let p = point(CGPoint(x: min(max(gazePoint.x, -0.05), 1.05), y: min(max(gazePoint.y, top), 1.05)))
                    let radius: CGFloat = id == gaze.activeEngineID ? 6 : 4.5
                    context.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: 2 * radius, height: 2 * radius)),
                                 with: .color(engineColor(id).opacity(output.isBlinking || output.isGlitch ? 0.35 : 1)))
                }
            }
            HStack(spacing: 10) {
                ForEach(gaze.engineIDs, id: \.self) { id in
                    HStack(spacing: 4) {
                        Circle().fill(engineColor(id)).frame(width: 7, height: 7)
                        Text(id + (gaze.outputs[id]?.wantsExpanded == true ? " open" : ""))
                            .fontWeight(id == gaze.activeEngineID ? .bold : .regular)
                    }
                }
            }
            .font(.system(size: 10))
        }
    }
}

/// The camera feed, mirrored like a mirror. Also used by the preview in Settings.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewView { CameraPreviewView(session: session) }

    func updateNSView(_ view: CameraPreviewView, context: Context) { view.mirror() }
}

/// The preview layer has no connection until the camera is configured, which often happens
/// after the preview appears; mirroring is applied again once the session runs.
final class CameraPreviewView: NSView {
    private let preview: AVCaptureVideoPreviewLayer
    private var observer: NSObjectProtocol?

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        super.init(frame: .zero)
        layer = preview
        wantsLayer = true
        mirror()
        observer = NotificationCenter.default.addObserver(forName: AVCaptureSession.didStartRunningNotification,
                                                          object: session, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.mirror() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func mirror() {
        guard let connection = preview.connection, connection.isVideoMirroringSupported, !connection.isVideoMirrored else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = true
    }
}
