import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Development aid (`--debug-snapshots <dir>`): saves what the screen shows under the island window.
enum DebugSnapshot {
    /// One window on its own, keeping its transparency.
    @MainActor static func captureWindow(_ windowID: CGWindowID, to url: URL) {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let window = content.windows.first(where: { $0.windowID == windowID }) else { return }
                let config = SCStreamConfiguration()
                config.width = Int(window.frame.width * 2)
                config.height = Int(window.frame.height * 2)
                config.showsCursor = false
                config.pixelFormat = kCVPixelFormatType_32BGRA
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: window),
                                                                       configuration: config)
                write(image, to: url)
            } catch {
                Log.info("debug window snapshot failed: \(error.localizedDescription)")
            }
        }
    }

    private static func write(_ image: CGImage, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    @MainActor static func capture(rect: NSRect, to url: URL) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        // sourceRect is in display points with a top-left origin.
        let source = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { return }
                let config = SCStreamConfiguration()
                config.sourceRect = source
                config.width = Int(source.width * 2)
                config.height = Int(source.height * 2)
                config.showsCursor = true
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                write(image, to: url)
            } catch {
                Log.info("debug snapshot failed: \(error.localizedDescription)")
            }
        }
    }
}
