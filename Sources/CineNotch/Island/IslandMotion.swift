import AppKit
import QuartzCore

/// A spring with SwiftUI's parameters (response in seconds, damping fraction), stepped by
/// hand so that every part of the island can run on its own spring and start delay.
struct MotionSpring {
    struct Curve {
        var response: Double
        var damping: Double
        var delay: Double = 0
    }

    private(set) var value: Double
    private var velocity = 0.0
    private var target: Double
    private var curve = Curve(response: 0.3, damping: 1)
    private var pending: (at: TimeInterval, target: Double, curve: Curve)?

    init(_ value: Double) {
        self.value = value
        target = value
    }

    var isResting: Bool { pending == nil && value == target && velocity == 0 }
    /// Where the spring is headed, including a target that hasn't started yet.
    var finalTarget: Double { pending?.target ?? target }

    /// A delayed target replaces any other pending one but leaves the current motion alone
    /// until it starts.
    mutating func set(_ newTarget: Double, _ newCurve: Curve, now: TimeInterval) {
        if newCurve.delay > 0 {
            pending = (now + newCurve.delay, newTarget, newCurve)
        } else {
            pending = nil
            target = newTarget
            curve = newCurve
        }
    }

    mutating func jump(_ newValue: Double) {
        value = newValue
        target = newValue
        velocity = 0
        pending = nil
    }

    mutating func step(_ dt: Double, now: TimeInterval) {
        if let pending, now >= pending.at {
            target = pending.target
            curve = pending.curve
            self.pending = nil
        }
        guard value != target || velocity != 0 else { return }
        let omega = 2 * Double.pi / curve.response
        let stiffness = omega * omega, friction = 2 * curve.damping * omega
        let steps = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / Double(steps)
        for _ in 0..<steps {
            velocity += (-stiffness * (value - target) - friction * velocity) * h
            value += velocity * h
        }
        if abs(value - target) < 1e-3, abs(velocity) < 1e-2 {
            value = target
            velocity = 0
        }
    }
}

/// Everything that moves in the island, on springs driven by the display.
///
/// Positions inside the island are kept relative to its center, so its width and height can
/// move on separate springs without dragging the content sideways.
@MainActor
final class IslandMotion: NSObject, ObservableObject {
    enum Part: Int, CaseIterable {
        case width, height, topRadius, bottomRadius
        case videoX, videoY, videoW, videoH, videoRadius
        case titleX, titleY, titleW, titleH
        case ringX, ringY, ringSize
        case barX, barY, barW, barH
        case controlsX, controlsY, controlsW
        case barAlpha, barGrow, opacity, content, glow
        case bump, eyes, eyeLook, desaturate, spinBack, spinForward
        case control0, control1, control2, control3, control4
    }

    typealias Curve = MotionSpring.Curve

    /// How far the island leans out towards you while a glance at the camera builds up.
    static let bumpDepth: CGFloat = 14
    /// Expansion spring (the height, the video and the controls), tuned in the motion prototype.
    static let expandCurve = Curve(response: 0.42, damping: 0.8)
    /// Controls fade in from the middle out, this far apart.
    static let controlStagger = 0.03

    var metrics: IslandMetrics
    var aspect: CGFloat = 16.0 / 9.0
    /// Below 1 plays everything in slow motion (`--debug-slow-motion`).
    var timeScale = 1.0
    /// The eyes sit inside a dot-sized island (no notch) while saying hello, not under it.
    private(set) var eyesInside = false

    private var springs = Part.allCases.map { _ in MotionSpring(0) }
    private var events: [(at: TimeInterval, action: () -> Void)] = []
    private var link: CADisplayLink?
    private var lastTick: TimeInterval = 0
    /// Animation time: advances with the display, scaled by `timeScale`.
    private var now: TimeInterval = 0
    private var isVisible = false
    private var isExpanded = false
    private var isPaused = false
    private var charge = 0.0
    /// Who drives the eyes and the bump: the gaze charge, the hello on appear, or a reveal.
    private enum EyesOwner { case charge, hello, reveal }
    private var eyesOwner = EyesOwner.charge
    private var nextLook: TimeInterval = 0

    init(metrics: IslandMetrics) {
        self.metrics = metrics
        super.init()
        snap(visible: false, expanded: false)
    }

    subscript(_ part: Part) -> CGFloat { CGFloat(springs[part.rawValue].value) }

    func control(_ index: Int) -> CGFloat { self[Part(rawValue: Part.control0.rawValue + index)!] }

    /// Drives the springs from the display `view` is on.
    func attach(to view: NSView) {
        link?.invalidate()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        self.link = link
        wake()
    }

    // MARK: State changes

    /// Jumps to a state without animating (screen changes, launch).
    func snap(visible: Bool, expanded: Bool) {
        isVisible = visible
        isExpanded = visible && expanded
        let layout = currentLayout()
        jump(layout, shape: true)
        for part in [Part.opacity, .content] { springs[part.rawValue].jump(visible ? 1 : 0) }
        springs[Part.content.rawValue].jump(1)
        for i in 0..<5 { springs[Part.control0.rawValue + i].jump(isExpanded ? 1 : 0) }
        springs[Part.barAlpha.rawValue].jump(isExpanded ? 1 : 0)
        springs[Part.barGrow.rawValue].jump(1)
        springs[Part.glow.rawValue].jump(isExpanded ? 1 : 0)
        for part in [Part.bump, .eyes, .eyeLook, .spinBack, .spinForward] { springs[part.rawValue].jump(0) }
        springs[Part.desaturate.rawValue].jump(isPaused && !isExpanded ? 1 : 0)
        eyesOwner = .charge
        eyesInside = false
        events.removeAll()
        publish()
    }

    /// Picture in Picture started: the island grows out of the notch (or a dot), the mascot
    /// blinks hello, then the content fades in.
    func appear() {
        isVisible = true
        isExpanded = false
        events.removeAll()
        let layout = currentLayout(), now = clock()
        jump(layout, shape: false)
        let start = collapsedSeed()
        springs[Part.width.rawValue].jump(start.width)
        springs[Part.height.rawValue].jump(start.height)
        springs[Part.topRadius.rawValue].jump(layout.topRadius)
        springs[Part.bottomRadius.rawValue].jump(start.bottomRadius)
        springs[Part.opacity.rawValue].jump(metrics.hasNotch ? 1 : 0)
        set(.opacity, 1, Curve(response: 0.2, damping: 1))
        springs[Part.content.rawValue].jump(0)
        controls(expanded: false, instant: true)
        springs[Part.glow.rawValue].jump(0)

        hello(now: now)
        let hold = 0.72
        set(.width, Double(layout.size.width), Curve(response: 0.5, damping: 0.66, delay: hold + 0.02))
        set(.bottomRadius, Double(layout.bottomRadius), Curve(response: 0.4, damping: 0.9, delay: hold))
        set(.height, Double(layout.size.height), Curve(response: 0.4, damping: 0.85))
        set(.content, 1, Curve(response: 0.3, damping: 1, delay: hold + 0.16))
        wake()
    }

    /// Picture in Picture ended: the content fades and the island tucks back into the notch.
    func disappear() {
        isVisible = false
        isExpanded = false
        events.removeAll()
        eyesOwner = .charge
        let layout = currentLayout(), end = collapsedSeed()
        place(layout, all: Curve(response: 0.3, damping: 1))
        controls(expanded: false, instant: false)
        set(.glow, 0, Curve(response: 0.18, damping: 1))
        set(.content, 0, Curve(response: 0.14, damping: 1))
        set(.width, end.width, Curve(response: 0.34, damping: 0.95, delay: 0.08))
        set(.height, end.height, Curve(response: 0.3, damping: 1))
        set(.bottomRadius, end.bottomRadius, Curve(response: 0.3, damping: 1, delay: 0.08))
        set(.opacity, 0, Curve(response: 0.2, damping: 1, delay: metrics.hasNotch ? 0.55 : 0.34))
        wake()
    }

    /// Width first, then height; the controls fade in from the middle out and the progress
    /// bar grows from the left. Closing is quicker and in the reverse order.
    func setExpanded(_ expanded: Bool) {
        guard isVisible, expanded != isExpanded else { return }
        isExpanded = expanded
        let layout = currentLayout()
        if expanded {
            let e = Self.expandCurve, settled = Curve(response: e.response, damping: min(1, e.damping + 0.04), delay: 0.03)
            place(layout,
                  width: Curve(response: 0.34, damping: 0.72),
                  height: Curve(response: e.response, damping: e.damping, delay: 0.045),
                  video: settled, videoRadius: Curve(response: 0.35, damping: 1, delay: 0.03),
                  text: Curve(response: 0.34, damping: 0.86), bar: settled, controls: settled)
            set(.glow, 1, Curve(response: 0.6, damping: 1, delay: 0.22))
        } else {
            let quick = Curve(response: 0.32, damping: 0.92)
            place(layout,
                  width: Curve(response: 0.36, damping: 0.8, delay: 0.05),
                  height: quick, video: Curve(response: 0.34, damping: 0.92), videoRadius: Curve(response: 0.3, damping: 1),
                  text: quick, bar: quick, controls: quick)
            set(.glow, 0, Curve(response: 0.22, damping: 1))
        }
        controls(expanded: expanded, instant: false)
        updateDesaturation()
        wake()
    }

    /// The video changed shape while docked.
    func relayout() {
        let all = Curve(response: 0.36, damping: 0.86)
        place(currentLayout(), all: all)
        wake()
    }

    /// 0...1 while a glance at the camera builds up to a reveal.
    func setCharge(_ value: Double) {
        guard value != charge else { return }
        charge = value
        wake()
    }

    /// A glance revealed the video: the eyes blink and the bump melts into the expanding island.
    func reveal() {
        eyesOwner = .reveal
        let now = clock()
        set(.eyes, 0, Curve(response: 0.1, damping: 1, delay: 0.04))
        set(.bump, 0, Curve(response: 0.2, damping: 1))
        schedule(at: now + 0.55) { [weak self] in
            if self?.eyesOwner == .reveal { self?.eyesOwner = .charge }
        }
        wake()
    }

    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        updateDesaturation()
        wake()
    }

    /// The ±10 s arrows kick round and settle back.
    func spin(forward: Bool) {
        let part: Part = forward ? .spinForward : .spinBack
        springs[part.rawValue].jump(1)
        set(part, 0, Curve(response: 0.42, damping: 0.42))
        wake()
    }

    // MARK: Pieces

    private func hello(now: TimeInterval) {
        eyesOwner = .hello
        eyesInside = !metrics.hasNotch
        springs[Part.eyes.rawValue].jump(0)
        springs[Part.bump.rawValue].jump(0)
        if metrics.hasNotch {
            set(.bump, Double(Self.bumpDepth), Curve(response: 0.28, damping: 0.68, delay: 0.05))
        } else {
            set(.width, 64, Curve(response: 0.32, damping: 0.7))
        }
        set(.eyes, 1, Curve(response: 0.16, damping: 0.8, delay: 0.12))
        schedule(at: now + 0.5) { [weak self] in self?.helloStep { $0.set(.eyes, 0, Curve(response: 0.05, damping: 1)) } }
        schedule(at: now + 0.57) { [weak self] in self?.helloStep { $0.set(.eyes, 1, Curve(response: 0.07, damping: 1)) } }
        schedule(at: now + 0.72) { [weak self] in
            self?.helloStep {
                $0.set(.eyes, 0, Curve(response: 0.13, damping: 1))
                $0.set(.bump, 0, Curve(response: 0.26, damping: 0.9))
            }
        }
        schedule(at: now + 1.0) { [weak self] in
            self?.helloStep {
                $0.eyesOwner = .charge
                $0.eyesInside = false
            }
        }
    }

    private func helloStep(_ body: (IslandMotion) -> Void) {
        if eyesOwner == .hello { body(self) }
    }

    private func controls(expanded: Bool, instant: Bool) {
        // Play first, then the arrows, then the outer buttons.
        for (rank, index) in [2, 1, 3, 0, 4].enumerated() {
            let part = Part(rawValue: Part.control0.rawValue + index)!
            if instant {
                springs[part.rawValue].jump(expanded ? 1 : 0)
            } else if expanded {
                set(part, 1, Curve(response: 0.3, damping: 0.8, delay: 0.11 + Double((rank + 1) / 2) * Self.controlStagger))
            } else {
                set(part, 0, Curve(response: 0.13, damping: 1))
            }
        }
        if instant {
            springs[Part.barAlpha.rawValue].jump(expanded ? 1 : 0)
            springs[Part.barGrow.rawValue].jump(1)
        } else if expanded {
            set(.barAlpha, 1, Curve(response: 0.22, damping: 1, delay: 0.1))
            if self[.barAlpha] < 0.05 { springs[Part.barGrow.rawValue].jump(0) }
            set(.barGrow, 1, Curve(response: 0.5, damping: 0.95, delay: 0.14))
        } else {
            set(.barAlpha, 0, Curve(response: 0.13, damping: 1))
        }
    }

    private func updateDesaturation() {
        set(.desaturate, isPaused && !isExpanded ? 1 : 0, Curve(response: 0.3, damping: 1))
    }

    /// The bump and the eyes follow the gaze charge.
    private func followCharge() {
        guard eyesOwner == .charge else { return }
        let c = isExpanded || !isVisible ? 0 : charge
        let eased = 1 - pow(1 - c, 3)
        set(.bump, Double(Self.bumpDepth) * eased, Curve(response: 0.16, damping: 0.78))
        let t = min(max((c - 0.15) / 0.45, 0), 1)
        set(.eyes, t * t * (3 - 2 * t), Curve(response: 0.12, damping: 0.9))
    }

    /// Small saccades while the eyes are open.
    private func lookAround(now: TimeInterval) {
        guard self[.eyes] > 0.05, now >= nextLook else { return }
        nextLook = now + 1 + Double.random(in: 0...0.8)
        set(.eyeLook, Double.random(in: -2.2...2.2), Curve(response: 0.12, damping: 0.8))
    }

    /// The island's size at the start of `appear` and the end of `disappear`.
    private func collapsedSeed() -> (width: Double, height: Double, bottomRadius: Double) {
        if let notch = metrics.notch {
            return (Double(notch.width), Double(metrics.pillHeight), 10)
        }
        return (22, Double(metrics.pillHeight), Double(metrics.pillHeight) / 2)
    }

    private func currentLayout() -> IslandLayout {
        metrics.layout(expanded: isExpanded, aspect: aspect)
    }

    // MARK: Springs

    private func clock() -> TimeInterval { now }

    private func set(_ part: Part, _ value: Double, _ curve: Curve) {
        springs[part.rawValue].set(value, curve, now: clock())
    }

    private func schedule(at time: TimeInterval, _ action: @escaping () -> Void) {
        events.append((time, action))
    }

    /// Values of a layout, relative to the island's center.
    private func values(_ layout: IslandLayout) -> [(Part, CGFloat)] {
        let mid = layout.size.width / 2
        return [
            (.videoX, layout.video.minX - mid), (.videoY, layout.video.minY), (.videoW, layout.video.width), (.videoH, layout.video.height),
            (.videoRadius, layout.videoRadius),
            (.titleX, layout.title.minX - mid), (.titleY, layout.title.minY), (.titleW, layout.title.width), (.titleH, layout.title.height),
            (.ringX, layout.ring.minX - mid), (.ringY, layout.ring.minY), (.ringSize, layout.ring.width),
            (.barX, layout.progressBar.minX - mid), (.barY, layout.progressBar.minY), (.barW, layout.progressBar.width), (.barH, layout.progressBar.height),
            (.controlsX, layout.controls.minX - mid), (.controlsY, layout.controls.minY), (.controlsW, layout.controls.width),
        ]
    }

    private func jump(_ layout: IslandLayout, shape: Bool) {
        for (part, value) in values(layout) { springs[part.rawValue].jump(Double(value)) }
        guard shape else { return }
        springs[Part.width.rawValue].jump(Double(layout.size.width))
        springs[Part.height.rawValue].jump(Double(layout.size.height))
        springs[Part.topRadius.rawValue].jump(Double(layout.topRadius))
        springs[Part.bottomRadius.rawValue].jump(Double(layout.bottomRadius))
    }

    private func place(_ layout: IslandLayout, all: Curve) {
        place(layout, width: all, height: all, video: all, videoRadius: all, text: all, bar: all, controls: all)
    }

    private func place(_ layout: IslandLayout, width: Curve, height: Curve, video: Curve, videoRadius: Curve,
                       text: Curve, bar: Curve, controls: Curve) {
        set(.width, Double(layout.size.width), width)
        set(.topRadius, Double(layout.topRadius), width)
        set(.bottomRadius, Double(layout.bottomRadius), width)
        set(.height, Double(layout.size.height), height)
        for (part, value) in values(layout) {
            let curve: Curve
            switch part {
            case .videoX, .videoY, .videoW, .videoH: curve = video
            case .videoRadius: curve = videoRadius
            case .barX, .barY, .barW, .barH: curve = bar
            case .controlsX, .controlsY, .controlsW: curve = controls
            default: curve = text
            }
            set(part, Double(value), curve)
        }
    }

    // MARK: Display link

    private func wake() {
        guard let link, link.isPaused else { return }
        lastTick = CACurrentMediaTime()
        link.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let real = CACurrentMediaTime()
        let dt = min(max(real - lastTick, 0), 1.0 / 20) * timeScale
        lastTick = real
        now += dt
        let due = events.filter { $0.at <= now }
        events.removeAll { $0.at <= now }
        due.forEach { $0.action() }
        followCharge()
        lookAround(now: now)
        var moving = false
        for i in springs.indices {
            springs[i].step(dt, now: now)
            if !springs[i].isResting { moving = true }
        }
        publish()
        if !moving, events.isEmpty { link.isPaused = true }
    }

    private func publish() {
        objectWillChange.send()
    }
}
