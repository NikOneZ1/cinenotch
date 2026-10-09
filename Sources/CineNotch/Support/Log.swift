import Foundation
import os

/// Logs to the unified log (subsystem `com.cinenotch`) and to ~/Library/Logs/CineNotch.log.
enum Log {
    private static let logger = Logger(subsystem: "com.cinenotch", category: "app")
    private static let queue = DispatchQueue(label: "com.cinenotch.log")
    private static let handle: FileHandle? = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CineNotch.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }()
    private static let timestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        queue.async {
            let line = "\(timestamp.string(from: Date())) \(message)\n"
            handle?.write(Data(line.utf8))
        }
    }
}
