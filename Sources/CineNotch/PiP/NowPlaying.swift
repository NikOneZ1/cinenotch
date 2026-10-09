import Foundation

/// macOS's Now Playing: what plays, from which app, and play/pause/seek for it. Chrome publishes
/// its Picture in Picture video there, which is how the island controls Chrome.
///
/// Since macOS 15.4 the private MediaRemote framework answers only Apple's own processes, so the
/// work happens in a helper: /usr/bin/perl, which macOS still lets in, running the
/// NowPlayingBridge library from the app bundle. It prints a JSON line whenever Now Playing
/// changes and takes commands on stdin (see NowPlayingBridge.m). Apple may close this; then the
/// bridge reports nothing and Chrome's controls stay hidden.
@MainActor
final class NowPlaying {
    struct State: Equatable {
        var pid: pid_t
        var title: String
        /// Nil for live streams.
        var duration: Double?
        var elapsed: Double
        var rate: Double
        /// When `elapsed` was measured.
        var timestamp: Date

        var isPlaying: Bool { rate > 0 }

        func position(at date: Date = Date()) -> Double {
            let position = elapsed + (isPlaying ? rate * date.timeIntervalSince(timestamp) : 0)
            return duration.map { min(max(position, 0), $0) } ?? max(position, 0)
        }
    }

    private(set) var state: State?
    var onChange: (() -> Void)?

    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var wanted = false
    private var failures = 0

    func start() {
        wanted = true
        if process == nil { launch() }
    }

    func stop() {
        wanted = false
        failures = 0
        if state != nil {
            state = nil
            onChange?()
        }
        guard let process else { return }
        self.process = nil
        // The bridge exits when its stdin closes.
        try? input?.close()
        input = nil
        if process.isRunning { process.terminate() }
    }

    func play() { send("play") }
    func pause() { send("pause") }
    func seek(to seconds: Double) { send("seek \(seconds)") }

    private func send(_ command: String) {
        try? input?.write(contentsOf: Data((command + "\n").utf8))
    }

    // MARK: Bridge process

    private static var bridgeURL: URL? {
        let candidates = [
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libNowPlayingBridge.dylib"),
            // `swift run`: next to the executable.
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("libNowPlayingBridge.dylib"),
        ]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Loads the library into perl and calls into it, as an XSUB.
    private static let loader = """
        use DynaLoader;
        my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error() . "\\n";
        my $main = DynaLoader::dl_find_symbol($lib, "cinenotch_now_playing_main") or die DynaLoader::dl_error() . "\\n";
        DynaLoader::dl_install_xsub("main::bridge", $main);
        bridge();
        """

    private func launch() {
        guard let bridge = Self.bridgeURL else {
            Log.info("now playing: bridge library missing")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.loader, bridge.path]
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.consume(data) } }
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                Log.info("now playing bridge: \(text)")
            }
        }
        process.terminationHandler = { [weak self] ended in
            let status = ended.terminationStatus
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.terminated(ended, status: status) } }
        }
        do {
            try process.run()
        } catch {
            Log.info("now playing: can't start perl: \(error.localizedDescription)")
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        buffer.removeAll()
        Log.info("now playing: bridge started, pid \(process.processIdentifier)")
    }

    private func terminated(_ ended: Process, status: Int32) {
        guard ended === process else { return }
        process = nil
        input = nil
        if state != nil {
            state = nil
            onChange?()
        }
        guard wanted else { return }
        failures += 1
        Log.info("now playing: bridge exited with status \(status)")
        guard failures < 5 else {
            Log.info("now playing: giving up on the bridge")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.wanted, self.process == nil else { return }
            self.launch()
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            parse(line)
        }
    }

    private func parse(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value else { return }
        failures = 0
        var new: State?
        if pid > 0 {
            let duration = (object["duration"] as? NSNumber)?.doubleValue
            let timestamp = (object["timestamp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            new = State(pid: pid,
                        title: object["title"] as? String ?? "",
                        duration: duration.flatMap { $0 > 0 ? $0 : nil },
                        elapsed: (object["elapsed"] as? NSNumber)?.doubleValue ?? 0,
                        rate: (object["rate"] as? NSNumber)?.doubleValue ?? 0,
                        timestamp: timestamp ?? Date())
        }
        guard new != state else { return }
        state = new
        onChange?()
    }
}
