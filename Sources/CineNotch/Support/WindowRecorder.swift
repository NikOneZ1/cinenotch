import AVFoundation
import ScreenCaptureKit

/// `--debug-record <file.mov>`: records one window on its own, transparency included, into a
/// HEVC-with-alpha movie, for promo videos. Movie time 0 is the moment recording started.
final class WindowRecorder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "com.cinenotch.recorder")
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime = CMTime.zero

    init(url: URL) {
        self.url = url
    }

    @MainActor func start(windowID: CGWindowID, size: CGSize, scale: CGFloat) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw NSError(domain: "CineNotch", code: 2, userInfo: [NSLocalizedDescriptionKey: "window \(windowID) not found"])
        }
        let width = Int(size.width * scale) & ~1, height = Int(size.height * scale) & ~1
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = false
        config.queueDepth = 8

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevcWithAlpha,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = true
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "CineNotch", code: 3) }
        let start = CMClockGetTime(CMClockGetHostTimeClock())
        writer.startSession(atSourceTime: start)
        queue.sync {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.startTime = start
        }

        let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.info("recording window \(windowID) to \(url.path), \(width)×\(height)")
    }

    @MainActor func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                guard let writer = self.writer else { return done.resume() }
                self.input?.markAsFinished()
                writer.finishWriting {
                    Log.info("recording finished: \(writer.status == .completed ? "ok" : String(describing: writer.error))")
                    done.resume()
                }
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let input, input.isReadyForMoreMediaData else { return }
        let time = sampleBuffer.presentationTimeStamp
        guard time >= startTime else { return }
        adaptor?.append(pixelBuffer, withPresentationTime: time)
    }
}
