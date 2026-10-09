import AVFoundation

/// The built-in camera, delivering frames on a private queue at up to `maxFPS`.
final class CameraFeed: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// Called on the camera queue.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// The analyzed frames come mirrored, like a mirror (read only, for drawing over a preview).
    private(set) var deliversMirroredFrames = false

    private let maxFPS: Double = 15
    private let queue = DispatchQueue(label: "com.cinenotch.camera", qos: .userInitiated)
    private var configured = false
    private var lastFrame = CFAbsoluteTime(0)

    func start() {
        queue.async { [self] in
            if !configured { configure() }
            if configured, !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        guard let device = Self.builtInCamera() else {
            Log.info("camera: no camera found")
            return
        }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            Log.info("camera: can't use \(device.localizedName)")
            return
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        deliversMirroredFrames = output.connection(with: .video)?.isVideoMirrored ?? false
        session.commitConfiguration()
        limitFrameRate(of: device)
        configured = true
        Log.info("camera: using \(device.localizedName)")
    }

    /// The camera above the built-in display, where the island is.
    static func builtInCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified)
            .devices.first ?? AVCaptureDevice.default(for: .video)
    }

    private func limitFrameRate(of device: AVCaptureDevice) {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard ranges.contains(where: { $0.minFrameRate <= maxFPS && maxFPS <= $0.maxFrameRate }),
              (try? device.lockForConfiguration()) != nil else {
            Log.info("camera: can't limit to \(maxFPS) fps, supported: \(ranges.map { "\($0.minFrameRate)-\($0.maxFrameRate)" })")
            return
        }
        let duration = CMTime(value: 1, timescale: CMTimeScale(maxFPS))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // The camera may not support 15 fps natively; drop the extra frames here.
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastFrame >= 1 / maxFPS - 0.005, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastFrame = now
        onFrame?(pixelBuffer)
    }
}

enum CameraAccess {
    static var status: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    static func request(_ completion: @escaping @MainActor (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(granted) } }
        }
    }

    static func openSettings() { Permissions.openSettings(anchor: "Privacy_Camera") }
}
