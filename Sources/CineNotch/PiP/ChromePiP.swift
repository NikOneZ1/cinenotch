import AppKit
import ApplicationServices

/// Chrome draws its own Picture in Picture window instead of using the system one: a floating
/// window of the browser process. It can be parked and captured like the system window, but its
/// buttons exist only while the real cursor is over it, and it doesn't report progress.
enum ChromePiP {
    static let bundleIDs = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"]

    struct Window {
        let pid: pid_t
        let windowID: CGWindowID
        let element: AXUIElement
    }

    /// Chrome keeps its accessibility tree off until something asks for it. These processes
    /// have been asked to turn it on.
    @MainActor private static var woken: Set<pid_t> = []

    /// The PiP window of a running Chrome. `known` is the window docked now: while it lasts it's
    /// returned without asking Chrome again.
    @MainActor static func find(known: Window?) -> Window? {
        let pids = bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .map(\.processIdentifier)
        guard !pids.isEmpty else { return nil }
        // Unlike the system window, Chrome's stays on the Space it was opened on: on another
        // Space it's off screen, but still there.
        if let known, pids.contains(known.pid),
           let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, known.windowID) as? [[String: Any]])?.first,
           isFloating(info), AX.size(known.element) != nil {
            return known
        }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            // The PiP window floats; the browser windows and Chrome's bubbles sit at the normal level.
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid), isFloating(info),
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width >= 120, bounds.height >= 68 else { continue }
            if let element = axWindow(pid: pid, matching: bounds) {
                return Window(pid: pid, windowID: id, element: element)
            }
        }
        return nil
    }

    /// The accessibility element of the window at `bounds`. The first time, Chrome lists no
    /// windows at all: asking for the element under a point usually wakes it up, and if that
    /// fails, it's asked outright (`AXManualAccessibility`, as screen readers do).
    @MainActor private static func axWindow(pid: pid_t, matching bounds: CGRect) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if let window = AX.windows(of: app).first(where: { matches($0, bounds) }) { return window }

        if let point = visibleCenter(of: bounds) {
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0.25)
            var hit: AXUIElement?
            var owner: pid_t = 0
            if AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success, let hit,
               AXUIElementGetPid(hit, &owner) == .success, owner == pid {
                let window = AX.string(hit, kAXRoleAttribute) == kAXWindowRole ? hit : AX.element(hit, kAXWindowAttribute)
                if let window, matches(window, bounds) {
                    Log.info("chrome: found the PiP window through the element under it")
                    return window
                }
            }
        }

        if !woken.contains(pid) {
            woken.insert(pid)
            // Chrome reports this attribute as unsupported but turns accessibility on anyway.
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            Log.info("chrome: asked pid \(pid) to turn on accessibility")
        }
        return nil
    }

    private static func isFloating(_ info: [String: Any]) -> Bool {
        info[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.floatingWindow))
    }

    private static func matches(_ window: AXUIElement, _ bounds: CGRect) -> Bool {
        guard let frame = AX.frame(window) else { return false }
        return abs(frame.minX - bounds.minX) < 2 && abs(frame.minY - bounds.minY) < 2
            && abs(frame.width - bounds.width) < 2 && abs(frame.height - bounds.height) < 2
    }

    /// Center of the part of `bounds` (global, top-left origin) that is on a screen.
    @MainActor private static func visibleCenter(of bounds: CGRect) -> CGPoint? {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        for screen in NSScreen.screens {
            let f = screen.frame
            let visible = bounds.intersection(CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height))
            if !visible.isNull, visible.width >= 1, visible.height >= 1 { return CGPoint(x: visible.midX, y: visible.midY) }
        }
        return nil
    }

    // MARK: Title

    /// Title of the tab whose video is in Picture in Picture. Chrome marks that tab ("Me at the zoo -
    /// YouTube - Video playing in picture-in-picture mode"): in the window title while it's the
    /// active tab, and in the tab strip always. Without the mark (Chrome in another language),
    /// it's the active tab of the front window.
    @MainActor static func videoTitle(pid: pid_t, pipWindow: AXUIElement) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        let windows = AX.windows(of: app).filter { !CFEqual($0, pipWindow) }
        for window in windows {
            if let title = AX.string(window, kAXTitleAttribute), let video = beforeMark(title) { return video }
        }
        for window in windows {
            if let tab = markedTab(in: window), let title = AX.string(tab, kAXTitleAttribute), let video = beforeMark(title) {
                return video
            }
        }
        let front = AX.element(app, kAXMainWindowAttribute) ?? windows.first
        guard var title = front.flatMap({ AX.string($0, kAXTitleAttribute) }), !title.isEmpty else { return nil }
        if let suffix = title.range(of: " - Google Chrome", options: .backwards) { title = String(title[..<suffix.lowerBound]) }
        return VideoTitle.clean(title)
    }

    private static func isMark(_ text: String) -> Bool {
        text.range(of: "picture-in-picture", options: .caseInsensitive) != nil
            || text.range(of: "picture in picture", options: .caseInsensitive) != nil
    }

    /// The part of a window or tab title before Chrome's " - Video playing in picture-in-picture
    /// mode", cleaned up.
    private static func beforeMark(_ title: String) -> String? {
        let marks = ["picture-in-picture", "picture in picture"]
        guard let mark = marks.lazy.compactMap({ title.range(of: $0, options: .caseInsensitive) }).first,
              let separator = title.range(of: " - ", options: .backwards, range: title.startIndex..<mark.lowerBound) else { return nil }
        let video = VideoTitle.clean(String(title[..<separator.lowerBound]))
        return video.isEmpty ? nil : video
    }

    /// Brings the tab playing in Picture in Picture to the front.
    @MainActor static func showTab(pid: pid_t, pipWindow: AXUIElement) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        for window in AX.windows(of: app) where !CFEqual(window, pipWindow) {
            guard let tab = markedTab(in: window) else { continue }
            AX.press(tab)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            break
        }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// The tab-strip tab marked as playing in Picture in Picture. Walks the browser UI only: web
    /// pages are skipped, so Chrome doesn't have to build their accessibility trees.
    private static func markedTab(in window: AXUIElement) -> AXUIElement? {
        var queue = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 600 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            if AX.string(element, kAXSubroleAttribute) == "AXTabButton" {
                if let title = AX.string(element, kAXTitleAttribute), isMark(title) { return element }
                continue
            }
            guard depth < 12, AX.string(element, kAXRoleAttribute) != "AXWebArea" else { continue }
            queue += AX.children(of: element).map { ($0, depth + 1) }
        }
        return nil
    }
}
