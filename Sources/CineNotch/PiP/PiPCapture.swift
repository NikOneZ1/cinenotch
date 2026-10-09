import AppKit
import CoreMedia
import ScreenCaptureKit

/// Streams the PiP window with ScreenCaptureKit. The stream stays open the whole time the
/// window is docked (starting one takes ~250 ms); only the frame rate changes:
/// low while the island is collapsed (for the thumbnail), 60 fps while it is expanded.
final class PiPCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called on the main thread with every new frame.
    @MainActor var onFrame: ((IOSurface) -> Void)?
    @MainActor private(set) var isRunning = false

    @MainActor private var stream: SCStream?
    @MainActor private var size: CGSize = .zero
    @MainActor private var fast = false
    @MainActor private var generation = 0
    /// Frames since the stream started; logged once, to tell a live window from a frozen one.
    @MainActor private var frameCount = 0
    private let queue = DispatchQueue(label: "com.cinenotch.capture", qos: .userInteractive)

    @MainActor func start(windowID: CGWindowID, size: CGSize) {
        stop()
        self.size = size
        isRunning = true
        let gen = generation
        Task { @MainActor in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard gen == generation else { return }
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                    throw NSError(domain: "CineNotch", code: 1, userInfo: [NSLocalizedDescriptionKey: "window \(windowID) is not shareable"])
                }
                let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window),
                                      configuration: makeConfiguration(), delegate: self)
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
                try await stream.startCapture()
                guard gen == generation else {
                    try? await stream.stopCapture()
                    return
                }
                self.stream = stream
                frameCount = 0
                Log.info("capture started for window \(windowID)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, gen == self.generation else { return }
                    Log.info("capture: \(self.frameCount) frames in the first 5 s")
                }
            } catch {
                Log.info("capture failed: \(error.localizedDescription)")
                if gen == generation { isRunning = false }
            }
        }
    }

    @MainActor func stop() {
        generation += 1
        isRunning = false
        if let stream {
            self.stream = nil
            Task { try? await stream.stopCapture() }
        }
    }

    @MainActor func setFast(_ fast: Bool) {
        guard fast != self.fast else { return }
        self.fast = fast
        applyConfiguration()
    }

    @MainActor func setSize(_ size: CGSize) {
        guard size != self.size else { return }
        self.size = size
        applyConfiguration()
    }

    @MainActor private func applyConfiguration() {
        guard let stream else { return }
        let configuration = makeConfiguration()
        Task { try? await stream.updateConfiguration(configuration) }
    }

    @MainActor private func makeConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = max(2, Int(size.width * scale))
        config.height = max(2, Int(size.height * scale))
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false
        config.queueDepth = 5
        config.minimumFrameInterval = CMTime(value: 1, timescale: fast ? 60 : 10)
        return config
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.frameCount += 1
                self?.onFrame?(surface)
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.info("capture stopped: \(error.localizedDescription)")
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.stream === stream else { return }
                self.stream = nil
                self.isRunning = false
            }
        }
    }
}
