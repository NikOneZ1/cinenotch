import AppKit
import Combine
import SwiftUI

/// Owns the island window and decides when it is visible and expanded.
@MainActor
final class IslandController: ObservableObject {
    @Published private(set) var isVisible = false
    @Published private(set) var isExpanded = false
    @Published private(set) var metrics: IslandMetrics
    @Published var videoSize: IslandVideoSize {
        didSet {
            guard videoSize != oldValue else { return }
            UserDefaults.standard.set(videoSize.rawValue, forKey: Self.videoSizeKey)
            metrics.videoSize = videoSize
            motion.metrics = metrics
            motion.relayout()
            // The docked window follows, so the capture stays sharp at the new size.
            pip.resizeDocked()
            Log.info("video size: \(videoSize.rawValue)")
        }
    }
    /// Keeps the island expanded regardless of input (used by gaze calibration).
    var forceExpanded = false { didSet { refreshExpanded() } }
    /// Someone is behind the user: the island hides in the notch while the video stays docked.
    var isTuckedAway = false {
        didSet { if isTuckedAway != oldValue { setVisible(pip.isActive && !isTuckedAway) } }
    }
    /// Calibration and the gaze test script the island; a cursor resting over it must not interfere.
    var ignoresMouse = false {
        didSet {
            cancelPending()
            mouseWantsExpanded = false
            refreshExpanded()
        }
    }
    /// A target dot on the expanded video (calibration, gaze test), relative to the video (0...1, y down).
    @Published var videoMarker: CGPoint?
    @Published var videoMarkerProgress = 0.0
    /// Seconds a scroll over the open video just moved it, shown on the video for a moment.
    @Published private(set) var scrubbed: Int?

    let motion: IslandMotion
    let glow = AmbientGlow()

    /// Hover time before expanding; filters out the cursor just passing through the menu bar.
    private let expandDelay: TimeInterval = 0.06
    /// Time outside the island before collapsing.
    private let collapseDelay: TimeInterval = 0.3
    /// Trackpad scroll distance (points) per 10 s step.
    private let scrollStep: CGFloat = 40
    /// How far a pinch has to open or close to change the video size.
    private let pinchStep: CGFloat = 0.25
    private static let videoSizeKey = "videoSize"

    private let pip: PiPController
    private let options: LaunchOptions
    private let sink = FrameSink()
    private var panel: IslandPanel?
    private var monitors: [Any] = []
    private var timers: [Timer] = []
    private var pendingExpand: DispatchWorkItem?
    private var pendingCollapse: DispatchWorkItem?
    private var pendingSlowCapture: DispatchWorkItem?
    private var pendingClear: DispatchWorkItem?
    private var mouseWantsExpanded = false
    private var gazeWantsExpanded = false
    /// Opened with the keyboard shortcut: stays open until the shortcut closes it or the video goes.
    private var keyboardWantsExpanded = false
    private var scrollDistance: CGFloat = 0
    private var pinch: CGFloat = 0
    /// This pinch already changed the size: one step per pinch, so a long one doesn't run from
    /// small past large in one go.
    private var pinchStepped = false
    private var pendingScrubbedClear: DispatchWorkItem?
    private var debugCycleStep = 0
    private var cancellables = Set<AnyCancellable>()

    init(pip: PiPController, options: LaunchOptions) {
        self.pip = pip
        self.options = options
        let videoSize = IslandVideoSize(rawValue: UserDefaults.standard.string(forKey: Self.videoSizeKey) ?? "") ?? .medium
        self.videoSize = videoSize
        let metrics = IslandMetrics.current(debugNotch: options.debugNotch, videoSize: videoSize)
        self.metrics = metrics
        motion = IslandMotion(metrics: metrics)
        motion.aspect = pip.aspect
        if options.debugSlowMotion { motion.timeScale = 0.2 }
        pip.dockedVideoSize = { [weak self] aspect in
            self?.metrics.videoSize(aspect: aspect) ?? CGSize(width: 560, height: 560 / aspect)
        }
    }

    func start() {
        guard panel == nil else { return }
        let panel = IslandPanel(contentRect: metrics.panelFrame())
        let hosting = IslandHostingView(rootView: IslandView(island: self, pip: pip, motion: motion, glow: glow, sink: sink))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.orderFrontRegardless()
        self.panel = panel
        motion.attach(to: hosting)

        sink.observer = { [weak self] surface in self?.glow.consider(surface) }
        pip.capture.onFrame = { [weak self] surface in self?.sink.push(surface) }
        pip.$isActive
            .removeDuplicates()
            .sink { [weak self] active in
                guard let self else { return }
                setVisible(active && !isTuckedAway)
            }
            .store(in: &cancellables)
        pip.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in self?.motion.setPaused(!playing) }
            .store(in: &cancellables)
        pip.$aspect
            .removeDuplicates()
            .sink { [weak self] aspect in
                guard let self else { return }
                self.motion.aspect = aspect
                self.motion.relayout()
            }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screenChanged() }
        }

        if options.debugCycle {
            addTimer(interval: 3 / motion.timeScale) { [weak self] in self?.debugCycle() }
        } else if !options.debugDemo {
            installMouseTracking()
            installScrollSeeking()
        }
        Log.info("island started, metrics=\(metrics)")
    }

    func attachGaze(_ gaze: GazeController) {
        gaze.$charge
            .removeDuplicates()
            .sink { [weak self] charge in self?.motion.setCharge(charge) }
            .store(in: &cancellables)
        gaze.$wantsExpanded
            .removeDuplicates()
            .sink { [weak self] wants in self?.setGazeWantsExpanded(wants) }
            .store(in: &cancellables)
    }

    var panelWindowNumber: Int? { panel?.windowNumber }

    /// The latest video frame, for the menu.
    func thumbnail() -> CGImage? { isVisible ? sink.snapshot() : nil }

    /// Center of the expanded video in screen coordinates (bottom-left origin).
    func videoCenterOnScreen() -> CGPoint {
        let layout = metrics.layout(expanded: true, aspect: pip.aspect)
        let rect = metrics.screenRect(for: layout)
        return CGPoint(x: rect.minX + layout.video.midX, y: rect.maxY - layout.video.midY)
    }

    /// A point on the expanded video, given relative to it (0...1, y down), in screen coordinates.
    func videoPointOnScreen(_ spot: CGPoint) -> CGPoint {
        let layout = metrics.layout(expanded: true, aspect: pip.aspect)
        let rect = metrics.screenRect(for: layout)
        return CGPoint(x: rect.minX + layout.video.minX + layout.video.width * spot.x,
                       y: rect.maxY - layout.video.minY - layout.video.height * spot.y)
    }

    /// The collapsed island in screen coordinates (bottom-left origin).
    func collapsedRectOnScreen() -> CGRect {
        metrics.screenRect(for: metrics.layout(expanded: false, aspect: pip.aspect))
    }

    /// The expanded island in screen coordinates (bottom-left origin).
    func expandedRectOnScreen() -> CGRect {
        metrics.screenRect(for: metrics.layout(expanded: true, aspect: pip.aspect))
    }

    /// The expanded island relative to its screen: 0...1, y down.
    func expandedRectNormalized() -> CGRect {
        let rect = expandedRectOnScreen(), screen = metrics.screenFrame
        return CGRect(x: (rect.minX - screen.minX) / screen.width, y: (screen.maxY - rect.maxY) / screen.height,
                      width: rect.width / screen.width, height: rect.height / screen.height)
    }

    // MARK: State

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        pendingClear?.cancel()
        if !visible {
            cancelPending()
            mouseWantsExpanded = false
            // Keep the last frame while the content fades out.
            let work = DispatchWorkItem { [weak self] in
                self?.sink.clear()
                self?.glow.reset()
            }
            pendingClear = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
        if !visible, isExpanded {
            pendingSlowCapture?.cancel()
            pip.capture.setFast(false)
        }
        isVisible = visible
        isExpanded = false
        keyboardWantsExpanded = false
        if visible { motion.appear() } else { motion.disappear() }
        refreshExpanded()
        panel?.ignoresMouseEvents = true
        snapshot("visible-\(visible)")
    }

    private func setGazeWantsExpanded(_ wants: Bool) {
        gazeWantsExpanded = wants
        // The glance is what opens it: the eyes blink and the chin melts into the island.
        if wants, isVisible, !isExpanded { motion.reveal() }
        refreshExpanded()
    }

    /// The island is expanded while any input wants it: the cursor, a glance, or calibration.
    private func refreshExpanded() {
        setExpanded(isVisible && (mouseWantsExpanded || gazeWantsExpanded || keyboardWantsExpanded || forceExpanded))
    }

    private func setExpanded(_ expanded: Bool) {
        guard expanded != isExpanded else { return }
        pendingSlowCapture?.cancel()
        if expanded {
            pip.capture.setFast(true)
        } else {
            // Keep full frame rate until the collapse animation is over.
            let work = DispatchWorkItem { [weak self] in self?.pip.capture.setFast(false) }
            pendingSlowCapture = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
        isExpanded = expanded
        motion.setExpanded(expanded)
        snapshot(expanded ? "expand" : "collapse")
    }

    private func screenChanged() {
        metrics = IslandMetrics.current(debugNotch: options.debugNotch, videoSize: videoSize)
        motion.metrics = metrics
        motion.snap(visible: isVisible, expanded: isExpanded)
        panel?.setFrame(metrics.panelFrame(), display: true)
        Log.info("screen changed, metrics=\(metrics)")
    }

    /// The keyboard shortcut: opens the island and keeps it open, or closes it.
    func toggleFromKeyboard() {
        guard isVisible, !ignoresMouse else { return }
        keyboardWantsExpanded = !isExpanded
        if !keyboardWantsExpanded {
            cancelPending()
            mouseWantsExpanded = false
        }
        refreshExpanded()
    }

    // MARK: Mouse

    private func installMouseTracking() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.trackMouse() }
            return event
        }) {
            monitors.append(monitor)
        }
        // Safety net for moments without mouse events (screen changes, animations finishing).
        addTimer(interval: 0.1) { [weak self] in self?.trackMouse() }
    }

    private func trackMouse() {
        guard let panel else { return }
        guard isVisible else {
            panel.ignoresMouseEvents = true
            cancelPending()
            return
        }
        guard !ignoresMouse else {
            panel.ignoresMouseEvents = true
            return
        }
        let mouse = NSEvent.mouseLocation
        let collapsedRect = metrics.screenRect(for: metrics.layout(expanded: false, aspect: pip.aspect))
        let expandedRect = metrics.screenRect(for: metrics.layout(expanded: true, aspect: pip.aspect))

        // The pill plus a little slack, reaching up to the very top edge of the screen
        // so flicking the cursor to the top center always hits it.
        var hotZone = collapsedRect.insetBy(dx: -6, dy: -6)
        hotZone.size.height = metrics.screenFrame.maxY - hotZone.minY + 1

        let current = isExpanded ? expandedRect : collapsedRect
        let overIsland = current.contains(mouse)
        if panel.ignoresMouseEvents == overIsland { panel.ignoresMouseEvents = !overIsland }

        // Once the island is open (by any input), the cursor anywhere over it keeps it open.
        let inside = hotZone.contains(mouse) || (isExpanded && expandedRect.insetBy(dx: -10, dy: -10).contains(mouse))
        if inside {
            pendingCollapse?.cancel()
            pendingCollapse = nil
            if !mouseWantsExpanded, pendingExpand == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingExpand = nil
                    self?.mouseWantsExpanded = true
                    self?.refreshExpanded()
                }
                pendingExpand = work
                DispatchQueue.main.asyncAfter(deadline: .now() + (isExpanded ? 0 : expandDelay), execute: work)
            }
        } else {
            pendingExpand?.cancel()
            pendingExpand = nil
            if mouseWantsExpanded, pendingCollapse == nil {
                let work = DispatchWorkItem { [weak self] in
                    self?.pendingCollapse = nil
                    self?.mouseWantsExpanded = false
                    self?.refreshExpanded()
                }
                pendingCollapse = work
                DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: work)
            }
        }
    }

    // MARK: Scrolling

    /// Two fingers (or the wheel) over the open video move it in 10 s steps; a pinch over it
    /// changes the video size.
    private func installScrollSeeking() {
        let handle: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated {
                event.type == .magnify ? self?.pinched(event) : self?.scrolled(event)
            }
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel, .magnify], handler: handle) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify], handler: { event in
            handle(event)
            return event
        }) {
            monitors.append(monitor)
        }
    }

    /// Bigger or smaller by one size, from the keyboard shortcuts or a pinch.
    func stepVideoSize(bigger: Bool) {
        if let next = bigger ? videoSize.bigger : videoSize.smaller { videoSize = next }
    }

    private func pinched(_ event: NSEvent) {
        guard isVisible, isExpanded, !ignoresMouse, expandedRectOnScreen().contains(NSEvent.mouseLocation) else { return }
        if event.phase == .began {
            pinch = 0
            pinchStepped = false
        }
        guard !pinchStepped else { return }
        pinch += event.magnification
        guard abs(pinch) >= pinchStep else { return }
        pinchStepped = true
        stepVideoSize(bigger: pinch > 0)
    }

    private func scrolled(_ event: NSEvent) {
        guard isVisible, isExpanded, !ignoresMouse, pip.features.skip,
              expandedRectOnScreen().contains(NSEvent.mouseLocation) else { return }
        if event.phase == .began { scrollDistance = 0 }
        // The glide after a flick would run far past where the fingers stopped.
        guard event.momentumPhase.isEmpty else { return }
        // Fingers to the right or down (the wheel turned towards you) go forward, whatever the
        // scroll direction setting.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let dx = event.scrollingDeltaX * sign, dy = event.scrollingDeltaY * sign
        let delta = abs(dx) >= abs(dy) ? dx : dy
        guard delta != 0 else { return }
        let steps: Int
        if event.hasPreciseScrollingDeltas {
            scrollDistance += delta
            steps = Int(scrollDistance / scrollStep)
            scrollDistance -= CGFloat(steps) * scrollStep
        } else {
            steps = delta > 0 ? 1 : -1
        }
        guard steps != 0 else { return }
        scrub(steps: steps)
    }

    /// The demo's scroll: what a scroll of `steps` 10 s steps over the open video does.
    func simulateScroll(steps: Int) {
        guard isExpanded else { return }
        scrub(steps: steps)
    }

    private func scrub(steps: Int) {
        for _ in 0..<abs(steps) { pip.skip(forward: steps > 0) }
        scrubbed = (scrubbed ?? 0) + steps * 10
        pendingScrubbedClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scrubbed = nil }
        pendingScrubbedClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func cancelPending() {
        pendingExpand?.cancel()
        pendingExpand = nil
        pendingCollapse?.cancel()
        pendingCollapse = nil
    }

    private func addTimer(interval: TimeInterval, _ block: @escaping @MainActor () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in MainActor.assumeIsolated { block() } }
        timer.tolerance = interval * 0.3
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    // MARK: Debug

    /// `--debug-cycle`: every 3 s the next of: open as if hovered, close, a glance that gives
    /// up halfway, a glance that opens it, close.
    private func debugCycle() {
        guard isVisible else { return }
        debugCycleStep += 1
        switch debugCycleStep % 5 {
        case 1: forceExpanded = true
        case 2: forceExpanded = false
        case 3: simulateGlance(upTo: 0.6)
        case 4: simulateGlance(upTo: 1)
        default:
            gazeWantsExpanded = false
            refreshExpanded()
        }
    }

    /// Ramps the charge the way GazeController reports it (steps of 0.1), then reveals or lets go.
    func simulateGlance(upTo peak: Double) {
        let steps = Int((peak * 10).rounded())
        let stepTime = 0.035 / motion.timeScale
        for i in 1...steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + stepTime * Double(i)) { [weak self] in
                self?.motion.setCharge(Double(i) / 10)
            }
        }
        let peakTime = stepTime * Double(steps)
        if peak >= 1 {
            DispatchQueue.main.asyncAfter(deadline: .now() + peakTime) { [weak self] in
                self?.motion.setCharge(0)
                self?.setGazeWantsExpanded(true)
            }
        } else {
            snapshot("peek", delays: [peakTime * motion.timeScale, peakTime * motion.timeScale + 0.1])
            DispatchQueue.main.asyncAfter(deadline: .now() + peakTime + 0.15 / motion.timeScale) { [weak self] in self?.motion.setCharge(0) }
        }
    }

    /// Delays are in animation time: stretched under `--debug-slow-motion`.
    /// Ends a simulated glance: the user looked back at their work.
    func simulateLookAway() {
        gazeWantsExpanded = false
        refreshExpanded()
    }

    private func snapshot(_ name: String, delays: [Double] = [0.05, 0.1, 0.16, 0.25, 0.4, 0.7]) {
        guard let panel else { return }
        let stretch = 1 / motion.timeScale
        if let dir = options.debugIslandDir {
            // The island window alone (transparent), once settled, plus timed frames under slow motion.
            let window = CGWindowID(panel.windowNumber)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 * stretch) {
                DebugSnapshot.captureWindow(window, to: dir.appendingPathComponent("island-\(name).png"))
            }
            if options.debugSlowMotion {
                for delay in delays {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay * stretch) {
                        DebugSnapshot.captureWindow(window, to: dir.appendingPathComponent("island-\(name)-\(Int(delay * 1000))ms.png"))
                    }
                }
            }
        }
        guard let dir = options.debugSnapshotDir else { return }
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay * stretch) {
                DebugSnapshot.capture(rect: panel.frame, to: dir.appendingPathComponent("\(name)-\(Int(delay * 1000))ms.png"))
            }
        }
    }
}

final class IslandPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the menu bar (and the PiP window, which lives at the utility level).
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class IslandHostingView<Content: View>: NSHostingView<Content> {
    // Buttons react to the first click even though the panel never becomes key.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
