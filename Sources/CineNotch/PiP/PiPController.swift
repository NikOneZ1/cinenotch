import AppKit
import ApplicationServices
import Combine

/// Who drew the docked Picture in Picture window.
enum PiPSource: Equatable {
    /// macOS's own PiP window (PIPAgent): Safari and other apps built on AVKit.
    case system
    /// Chrome's own PiP window. See `ChromePiP`.
    case chrome

    /// What the window itself offers. Chrome's play state, progress and playback come from Now
    /// Playing instead, when it's about the same video (see `PiPController.chromeMedia`).
    var features: PiPFeatures {
        switch self {
        case .system: return PiPFeatures(progress: true, playPause: true, skip: true, close: true, back: true)
        case .chrome: return PiPFeatures(progress: false, playPause: false, skip: false, close: false, back: true)
        }
    }
}

/// What the docked window reports and which of its buttons CineNotch can press.
struct PiPFeatures: Equatable {
    var progress: Bool
    var playPause: Bool
    var skip: Bool
    var close: Bool
    /// Back to the app the video came from.
    var back: Bool
}

/// Finds a Picture in Picture window (the system's, owned by PIPAgent, or Chrome's), parks it
/// in the bottom-right corner of the screen where only a 1×1 pt corner stays on screen, and
/// exposes its state and buttons. The video itself is captured by `PiPCapture`.
@MainActor
final class PiPController: ObservableObject {
    /// A PiP window is docked into the island.
    @Published private(set) var isActive = false
    /// A PiP window exists but the user asked to keep it as a normal floating window.
    @Published private(set) var isReleased = false
    @Published private(set) var title = ""
    @Published private(set) var isPlaying = true
    /// 0...1, nil when PiP does not report progress (e.g. live streams).
    @Published private(set) var progress: Double?
    /// Width / height of the PiP window.
    @Published private(set) var aspect: CGFloat = 16.0 / 9.0
    @Published private(set) var source = PiPSource.system
    @Published private(set) var features = PiPSource.system.features

    let capture = PiPCapture()
    private let nowPlaying = NowPlaying()
    /// The last seek in Chrome's video and when it was sent.
    private var lastSeek: (target: Double, time: TimeInterval)?
    /// Size the PiP window is set to when docked; the island shows the video at this size.
    var dockedVideoSize: (_ aspect: CGFloat) -> CGSize = { CGSize(width: 560, height: 560 / $0) }

    var hasWindow: Bool { window != nil }

    private static let agentBundleID = "com.apple.PIPAgent"

    private var agentPID: pid_t?
    private var agent: AXUIElement?
    private var window: AXUIElement?
    /// The process that owns `window`.
    private var ownerPID: pid_t?
    private var windowID: CGWindowID?
    private var windowSize: CGSize = .zero
    /// Where the PiP window goes when released.
    private var homeFrame: CGRect?
    private var timer: Timer?
    private var nextCaptureAttempt = Date.distantPast
    private var nextTitleCheck = Date.distantPast
    /// The last Now Playing title that didn't match the docked video, logged once.
    private var loggedMismatch = ""

    init() {
        nowPlaying.onChange = { [weak self] in self?.applyNowPlaying() }
    }

    func start() {
        guard timer == nil, fakeTimer == nil else { return }
        if LaunchOptions.current.debugFakePiP {
            startFake()
            return
        }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    // MARK: Actions

    func togglePlay() {
        if fakeVideo != nil { return isPlaying.toggle() }
        guard features.playPause else { return }
        if source == .chrome {
            setPlaying(!isPlaying)
            return
        }
        press(["pause", "play"])
        refreshSoon()
    }

    /// Pauses a playing video; false when there was nothing to pause.
    @discardableResult func pause() -> Bool { setPlaying(false) }
    /// Plays a paused video; false when it was already playing.
    @discardableResult func play() -> Bool { setPlaying(true) }

    @discardableResult private func setPlaying(_ playing: Bool) -> Bool {
        if fakeVideo != nil {
            guard isPlaying != playing else { return false }
            isPlaying = playing
            return true
        }
        guard features.playPause else { return false }
        if source == .chrome {
            guard isPlaying != playing else { return false }
            playing ? nowPlaying.play() : nowPlaying.pause()
            // Now Playing confirms a moment later.
            isPlaying = playing
            return true
        }
        // The play button turns into pause and back, so the one shown is the play state.
        guard let button = button([playing ? "play" : "pause"]) else { return false }
        AX.press(button)
        refreshSoon()
        return true
    }

    func skip(forward: Bool) {
        if fakeVideo != nil {
            fakeProgress = min(max(fakeProgress + (forward ? 10 : -10) / Self.fakeLength, 0), 1)
            progress = (fakeProgress * 100).rounded() / 100
            // The picture moves a quarter as far, so a scroll reads as fast-forward, not a strobe.
            fakeTime = max(0, fakeTime + (forward ? 2.5 : -2.5))
            return
        }
        guard features.skip else { return }
        if source == .chrome {
            guard let media = chromeMedia else { return }
            // Steps in a row (a scroll) build on the last target: Now Playing reports the new
            // position a moment later.
            let now = ProcessInfo.processInfo.systemUptime
            let start = lastSeek.flatMap { now - $0.time < 1.5 ? $0.target : nil } ?? media.position()
            var target = max(start + (forward ? 10 : -10), 0)
            if let duration = media.duration {
                target = min(target, duration)
                progress = target / duration
            }
            lastSeek = (target, now)
            nowPlaying.seek(to: target)
            return
        }
        press([forward ? "skip-forward" : "skip-back"])
        refreshSoon()
    }

    /// Back to where the video came from: Safari takes it out of Picture in Picture, Chrome
    /// just shows its tab (its PiP window can't be closed from here).
    func returnToApp() {
        if fakeVideo != nil { return closeFake() }
        guard features.back else { return }
        switch source {
        case .system: press(["restore"])
        case .chrome:
            guard let ownerPID, let window else { return }
            ChromePiP.showTab(pid: ownerPID, pipWindow: window)
        }
    }

    func close() {
        if fakeVideo != nil { return closeFake() }
        guard features.close else { return }
        press(["close"])
    }

    /// Puts the PiP window back on screen as a normal floating window.
    func release() {
        guard let window else { return }
        isReleased = true
        isActive = false
        capture.stop()
        if let home = homeFrame {
            AX.setSize(window, home.size)
            AX.setPosition(window, home.origin)
        }
        Log.info("released PiP window to \(String(describing: homeFrame))")
    }

    /// Takes a released PiP window back into the island.
    func dock() {
        guard let window, isReleased else { return }
        isReleased = false
        if let frame = AX.frame(window) { homeFrame = frame }
        dockWindow(window)
    }

    // MARK: Polling

    private func tick() {
        guard AXIsProcessTrusted() else { return }
        guard let found = findWindow() else {
            detach()
            return
        }
        if let window, CFEqual(window, found.element) {
            refreshState()
            if !isReleased { keepDocked() }
        } else {
            attach(found)
        }
    }

    private struct FoundWindow {
        let element: AXUIElement
        let pid: pid_t
        let source: PiPSource
        var windowID: CGWindowID?
    }

    /// The window to dock: the docked one while it lasts, otherwise the system's before Chrome's.
    private func findWindow() -> FoundWindow? {
        let order: [PiPSource] = window != nil && source == .chrome ? [.chrome, .system] : [.system, .chrome]
        for source in order {
            switch source {
            case .system:
                if let found = systemWindow() { return found }
            case .chrome:
                if let found = ChromePiP.find(known: dockedChromeWindow) {
                    return FoundWindow(element: found.element, pid: found.pid, source: .chrome, windowID: found.windowID)
                }
            }
        }
        return nil
    }

    /// The docked window, when it's Chrome's.
    private var dockedChromeWindow: ChromePiP.Window? {
        guard source == .chrome, let window, let ownerPID, let windowID else { return nil }
        return ChromePiP.Window(pid: ownerPID, windowID: windowID, element: window)
    }

    private func systemWindow() -> FoundWindow? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.agentBundleID).first?.processIdentifier else {
            agentPID = nil
            agent = nil
            return nil
        }
        if pid != agentPID {
            agentPID = pid
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.25)
            agent = element
        }
        guard let agent, let element = Self.pipWindow(in: agent) else { return nil }
        return FoundWindow(element: element, pid: pid, source: .system)
    }

    private static func pipWindow(in agent: AXUIElement) -> AXUIElement? {
        let windows = AX.windows(of: agent)
        return windows.first { AX.string($0, kAXIdentifierAttribute) == "picture-in-picture" }
            ?? windows.first { (AX.size($0)?.width ?? 0) > 100 }
    }

    private func attach(_ found: FoundWindow) {
        detach()
        window = found.element
        ownerPID = found.pid
        source = found.source
        let frame = AX.frame(found.element) ?? .zero
        homeFrame = Parking.isParked(frame) ? Parking.defaultHome(for: frame.size) : frame
        windowID = found.windowID ?? WindowList.windowID(ownerPID: found.pid, matching: frame)
        title = videoTitle() ?? "Picture in Picture"
        nextTitleCheck = Date().addingTimeInterval(2)
        isReleased = false
        Log.info("attached \(found.source) PiP window id=\(windowID.map(String.init) ?? "nil") frame=\(frame) title='\(title)'")
        if source == .chrome { nowPlaying.start() }
        updateFeatures()
        refreshState()
        dockWindow(found.element)
    }

    private func videoTitle() -> String? {
        switch source {
        case .system: return SafariInfo.frontTabTitle()
        case .chrome:
            guard let ownerPID, let window else { return nil }
            return ChromePiP.videoTitle(pid: ownerPID, pipWindow: window)
        }
    }

    private func dockWindow(_ window: AXUIElement) {
        if let size = AX.size(window), size.height > 0 {
            // Chrome keeps its window inside the screen while resizing, so it first goes
            // where there's room for the new size.
            if source == .chrome { AX.setPosition(window, Parking.roomyPoint()) }
            AX.setSize(window, dockedVideoSize(size.width / size.height))
        }
        AX.setPosition(window, Parking.point())
        if let size = AX.size(window) { updateSize(size) }
        isActive = true
        startCapture()
    }

    private func detach() {
        guard window != nil else { return }
        Log.info("PiP window gone")
        capture.stop()
        nowPlaying.stop()
        window = nil
        ownerPID = nil
        windowID = nil
        windowSize = .zero
        isActive = false
        isReleased = false
        progress = nil
        isPlaying = true
    }

    private func keepDocked() {
        guard let window, let frame = AX.frame(window) else { return }
        if frame.size != windowSize { updateSize(frame.size) }
        let target = Parking.point()
        if abs(frame.minX - target.x) > 0.5 || abs(frame.minY - target.y) > 0.5 {
            AX.setPosition(window, target)
        }
        if windowID == nil, let pid = ownerPID {
            windowID = WindowList.windowID(ownerPID: pid, matching: AX.frame(window) ?? frame)
        }
        if !capture.isRunning, Date() >= nextCaptureAttempt { startCapture() }
    }

    private func startCapture() {
        guard let windowID else { return }
        nextCaptureAttempt = Date().addingTimeInterval(2)
        capture.start(windowID: windowID, size: windowSize)
    }

    private func updateSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        windowSize = size
        let newAspect = size.width / size.height
        if abs(newAspect - aspect) > 0.001 { aspect = newAspect }
        capture.setSize(size)
    }

    // MARK: State

    private func refreshState() {
        guard let window else { return }
        if source == .chrome {
            // The window shows nothing to read; the title follows the next video in the tab,
            // the rest comes from Now Playing.
            if Date() >= nextTitleCheck {
                nextTitleCheck = Date().addingTimeInterval(2)
                if let video = videoTitle(), video != title {
                    title = video
                    updateFeatures()
                }
            }
            applyChromeMedia()
            return
        }
        var playing: Bool?
        var percent: Double?
        for child in AX.children(of: window) {
            switch AX.string(child, kAXIdentifierAttribute) {
            case "pause": playing = true
            case "play": playing = false
            default:
                // The scrubber has no identifier; it reports progress as e.g. "33%".
                if AX.string(child, kAXRoleAttribute) == "AXUnknown",
                   let text = AX.string(child, "AXValueDescription") {
                    percent = Self.parsePercent(text)
                }
            }
        }
        if let playing, playing != isPlaying { isPlaying = playing }
        if percent != progress { progress = percent }
    }

    /// Now Playing, while it's about the docked Chrome video: from that Chrome, with a matching
    /// title (another tab may be playing music).
    private var chromeMedia: NowPlaying.State? {
        guard source == .chrome, let media = nowPlaying.state, media.pid == ownerPID else { return nil }
        guard VideoTitle.sameVideo(media.title, title) else {
            if media.title != loggedMismatch {
                loggedMismatch = media.title
                Log.info("now playing: '\(media.title)' isn't the docked video '\(title)'")
            }
            return nil
        }
        return media
    }

    private func updateFeatures() {
        var new = source.features
        if let media = chromeMedia {
            new.playPause = true
            new.skip = true
            new.progress = media.duration != nil
        }
        guard new != features else { return }
        if source == .chrome, new.playPause != features.playPause {
            Log.info("chrome: controls \(new.playPause ? "on" : "off") (Now Playing)")
        }
        features = new
    }

    private func applyNowPlaying() {
        guard window != nil, source == .chrome else { return }
        updateFeatures()
        applyChromeMedia()
    }

    private func applyChromeMedia() {
        guard let media = chromeMedia else {
            if progress != nil { progress = nil }
            return
        }
        if media.isPlaying != isPlaying { isPlaying = media.isPlaying }
        let fraction = media.duration.map { ((media.position() / $0) * 1000).rounded() / 1000 }
        if fraction != progress { progress = fraction }
    }

    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refreshState() }
    }

    private func press(_ identifiers: [String]) {
        if let button = button(identifiers) { AX.press(button) } else { Log.info("PiP button \(identifiers) not found") }
    }

    private func button(_ identifiers: [String]) -> AXUIElement? {
        guard let window else { return nil }
        return AX.children(of: window).first { identifiers.contains(AX.string($0, kAXIdentifierAttribute) ?? "") }
    }

    // MARK: Fake video (--debug-fake-pip)

    private static let fakeLength = 596.0
    private var fakeVideo: FakeVideo?
    private var fakeTimer: Timer?
    private var fakeTime = 0.0
    private var fakeProgress = 0.34

    private func startFake() {
        fakeVideo = FakeVideo(width: 1120, height: 630)
        title = "Golden hour drive · 4K"
        aspect = 16.0 / 9.0
        progress = fakeProgress
        isPlaying = true
        // The demo starts it on cue.
        isActive = !LaunchOptions.current.debugDemo
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fakeTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        fakeTimer = timer
        Log.info("fake PiP started")
    }

    private func fakeTick() {
        guard isActive, let fakeVideo else { return }
        if isPlaying {
            fakeTime += 1.0 / 30
            fakeProgress = min(1, fakeProgress + 1.0 / 30 / Self.fakeLength)
            // PiP reports whole percents.
            let percent = (fakeProgress * 100).rounded() / 100
            if percent != progress { progress = percent }
        }
        if let surface = fakeVideo.frame(at: fakeTime) { capture.onFrame?(surface) }
    }

    /// Starts or ends the fake Picture in Picture (the demo script).
    func setFakeActive(_ active: Bool) {
        guard fakeVideo != nil else { return }
        isActive = active
    }

    /// Closing the fake video brings it back two seconds later, to see both animations.
    private func closeFake() {
        isActive = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.isActive = true }
    }

    static func parsePercent(_ text: String) -> Double? {
        let digits = text.filter(\.isNumber)
        guard let value = Double(digits) else { return nil }
        return min(max(value / 100, 0), 1)
    }
}

/// Where the PiP window hides while docked.
enum Parking {
    /// Top-left corner for the PiP window so that only its (transparent, rounded) top-left
    /// pixel stays on screen: the bottom-right corner of the right-most display.
    /// Global coordinates, origin at the top-left of the primary display.
    @MainActor static func point() -> CGPoint {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return .zero }
        let target = screens.max { ($0.frame.maxX, -$0.frame.minY) < ($1.frame.maxX, -$1.frame.minY) } ?? primary
        return CGPoint(x: target.frame.maxX - 1, y: primary.frame.height - target.frame.minY - 1)
    }

    /// Top-left corner of the main screen's visible area, where any docked size fits.
    @MainActor static func roomyPoint() -> CGPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let primaryHeight = NSScreen.screens.first?.frame.height else { return .zero }
        return CGPoint(x: screen.visibleFrame.minX, y: primaryHeight - screen.visibleFrame.maxY)
    }

    @MainActor static func isParked(_ frame: CGRect) -> Bool {
        let p = point()
        return abs(frame.minX - p.x) < 2 && abs(frame.minY - p.y) < 2
    }

    /// Top-right corner of the main screen, where macOS puts PiP by default.
    @MainActor static func defaultHome(for size: CGSize) -> CGRect {
        guard let screen = NSScreen.main ?? NSScreen.screens.first,
              let primaryHeight = NSScreen.screens.first?.frame.height else { return CGRect(origin: .zero, size: size) }
        let visible = screen.visibleFrame
        let origin = CGPoint(x: visible.maxX - size.width - 16, y: primaryHeight - visible.maxY + 16)
        return CGRect(origin: origin, size: size)
    }
}

enum WindowList {
    /// The CGWindowID of the on-screen window of `ownerPID` whose bounds are closest to `frame`.
    static func windowID(ownerPID: pid_t, matching frame: CGRect) -> CGWindowID? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        var best: (id: CGWindowID, distance: CGFloat)?
        for info in list where (info[kCGWindowOwnerPID as String] as? pid_t) == ownerPID {
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
            let distance = abs(bounds.minX - frame.minX) + abs(bounds.minY - frame.minY)
                + abs(bounds.width - frame.width) + abs(bounds.height - frame.height)
            if best == nil || distance < best!.distance { best = (id, distance) }
        }
        return best?.id
    }
}

enum SafariInfo {
    private static let bundleIDs = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]

    /// Title of the active tab in the front Safari window. PiP is almost always started
    /// from that tab, so this is the video title.
    static func frontTabTitle() -> String? {
        for bundleID in bundleIDs {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, 0.25)
            let window = AX.element(element, kAXFocusedWindowAttribute)
                ?? AX.element(element, kAXMainWindowAttribute)
                ?? AX.windows(of: element).first
            if let title = window.flatMap({ AX.string($0, kAXTitleAttribute) }), !title.isEmpty {
                return VideoTitle.clean(title)
            }
        }
        return nil
    }
}

enum VideoTitle {
    /// Whether two titles name the same video: Now Playing has the page's media title, while
    /// the tab title often adds the site.
    static func sameVideo(_ a: String, _ b: String) -> Bool {
        let x = clean(a).lowercased(), y = clean(b).lowercased()
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x == y || x.contains(y) || y.contains(x)
    }

    /// A tab title without the unread count and the site name.
    static func clean(_ title: String) -> String {
        var s = title.replacingOccurrences(of: #"^\(\d+\)\s*"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+[-–—|]\s+(YouTube|Twitch|Vimeo)$"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
