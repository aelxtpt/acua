import AppKit
import ObjectiveC

@main enum RecordingOverlayFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        var now = start.addingTimeInterval(61.9)
        var stopped = 0
        var discarded = 0
        let overlay = EventStreamRecordingOverlay(now: { now },
            onStop: { stopped += 1 }, onDiscard: { discarded += 1 })
        defer { overlay.hide() }

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            guard condition() else {
                FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
                exit(1)
            }
            print("PASS \(name)")
        }
        func children(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { children($0) }
        }
        func pump(for seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }

        check("elapsed time truncates fractional seconds", EventStreamRecordingOverlay.elapsedText(startedAt: start, now: now) == "1:01")
        check("elapsed time clamps backward clock changes to zero",
              EventStreamRecordingOverlay.elapsedText(startedAt: start, now: start.addingTimeInterval(-1)) == "0:00")
        let secondary = NSRect(x: -1280, y: -90, width: 1280, height: 790)
        check("initial placement respects a secondary screen origin",
              EventStreamRecordingOverlay.origin(in: secondary) == NSPoint(x: -717.5, y: 3))
        check("dragged placement clamps to the chosen display's visible area",
              EventStreamRecordingOverlay.origin(in: secondary, preserving: NSPoint(x: 80, y: -180)) == NSPoint(x: -155, y: -90))

        // Expected initial origins for controlled visible frames.
        let expectedOrigins: [(String, NSRect, NSPoint)] = [
            ("normal", NSRect(x: 0, y: 57, width: 1600, height: 812), NSPoint(x: 722.5, y: 150)),
            ("secondary", NSRect(x: -1280, y: -90, width: 1280, height: 790), NSPoint(x: -717.5, y: 3)),
            ("exact-size", NSRect(x: 20, y: 30, width: 155, height: 56), NSPoint(x: 20, y: 30)),
            ("one-extra", NSRect(x: 20, y: 30, width: 156, height: 57), NSPoint(x: 20.5, y: 31)),
            ("tiny", NSRect(x: 20, y: 30, width: 100, height: 30), NSPoint(x: -35, y: 4)),
            ("zero", NSRect(x: 20, y: 30, width: 0, height: 0), NSPoint(x: -135, y: -26)),
            ("narrow", NSRect(x: 20, y: 30, width: 154, height: 500), NSPoint(x: 19, y: 123)),
            ("short", NSRect(x: 20, y: 30, width: 500, height: 55), NSPoint(x: 192.5, y: 29)),
            ("one-point", NSRect(x: 20, y: 30, width: 1, height: 1), NSPoint(x: -134, y: -25)),
            ("negative-origin", NSRect(x: -60, y: -80, width: 100, height: 30), NSPoint(x: -115, y: -106)),
            ("zero-width", NSRect(x: 20, y: 30, width: 0, height: 500), NSPoint(x: -135, y: 123)),
            ("zero-height", NSRect(x: 20, y: 30, width: 500, height: 0), NSPoint(x: 192.5, y: -26)),
        ]
        for (name, visible, expected) in expectedOrigins {
            check("initial origin: " + name, EventStreamRecordingOverlay.origin(in: visible) == expected)
        }

        overlay.show(startedAt: start)
        pump(for: 0.08)
        guard let panel = app.windows.first(where: { $0.title == "Record & Replay Recording Controls" }) as? NSPanel,
              let content = panel.contentView else {
            check("the native recording panel exists", false)
            return
        }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        check("the visible native panel is 155 by 56 and cannot take focus",
              panel.isVisible && panel.frame.size == NSSize(width: 155, height: 56)
                && !panel.canBecomeKey && !panel.canBecomeMain && !panel.isKeyWindow)
        // AppKit may quantize a half-point request even on a 2x display. Keep
        // the mathematical goldens exact, and compare window placement with
        // the same native setter on an independent, hidden standard panel.
        let placementBaseline = NSPanel(contentRect: NSRect(origin: .zero, size: panel.frame.size),
            styleMask: panel.styleMask, backing: .buffered, defer: false)
        placementBaseline.isReleasedWhenClosed = false
        defer { placementBaseline.close() }
        if let screen { placementBaseline.setFrameOrigin(EventStreamRecordingOverlay.origin(in: screen.visibleFrame)) }
        check("the native panel opens at the platform-applied bottom offset",
              screen != nil && panel.frame.origin == placementBaseline.frame.origin)

        let descendants = children(content)
        guard let clock = descendants.compactMap({ $0 as? NSTextField }).first,
              let stop = descendants.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "Stop Recording" }),
              let discard = descendants.compactMap({ $0 as? NSButton }).first(where: { $0.toolTip == "Discard Recording" }) else {
            check("the panel exposes a clock and both native controls", false)
            return
        }
        check("the native clock renders elapsed minutes and seconds immediately", clock.stringValue == "1:01")
        let deadline = Date().addingTimeInterval(2)
        now = start.addingTimeInterval(63.1)
        while clock.stringValue != "1:03", Date() < deadline { pump(for: 0.02) }
        check("the repeating timer refreshes the real label", clock.stringValue == "1:03")

        stop.performClick(nil)
        discard.performClick(nil)
        check("the Stop and Discard controls deliver their own action", stopped == 1 && discarded == 1)

        let dragged = NSPoint(x: panel.frame.origin.x + 20, y: panel.frame.origin.y + 30)
        overlay.windowWillMove(Notification(name: NSWindow.willMoveNotification, object: panel))
        panel.setFrameOrigin(dragged)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: app)
        check("display changes preserve a valid dragged position", panel.frame.origin == dragged)

        overlay.hide()
        now = start.addingTimeInterval(120)
        pump(for: 1.2)
        check("hiding the overlay stops its timer and orders out the panel",
              !panel.isVisible && clock.stringValue == "1:03")
        overlay.show(startedAt: now)
        check("a new recording resets the timer and the panel position",
              panel.isVisible && clock.stringValue == "0:00" && panel.frame.origin != dragged)
        overlay.hide()
        RecordingOverlayScreenChoice.verify(overlay: overlay, panel: panel, startedAt: now) {
            check($0, $1)
        }
    }
}

@MainActor private enum RecordingOverlayScreenChoice {
    static var screen: NSScreen!
    static var panel: NSPanel!
    static var screensPresent = false
    static var copies = 1
    static var mouseReads = 0
    static var followingMouse: NSPoint?
    static var visibleOverride: Bool?
    static var mainPresent = false
    static var mouse = NSPoint.zero
    static var requested: NSPoint?
    static var suppressedFrontCalls = 0

    static func exchange(_ type: AnyClass, _ a: Selector, _ b: Selector) {
        method_exchangeImplementations(class_getInstanceMethod(type, a)!, class_getInstanceMethod(type, b)!)
    }
    static func toggle() {
        exchange(object_getClass(NSScreen.self)!, #selector(getter: NSScreen.screens), #selector(NSScreen.cua_overlayFixtureScreens))
        exchange(object_getClass(NSScreen.self)!, #selector(getter: NSScreen.main), #selector(NSScreen.cua_overlayFixtureMain))
        exchange(object_getClass(NSEvent.self)!, #selector(getter: NSEvent.mouseLocation), #selector(NSEvent.cua_overlayFixtureMouse))
        exchange(object_getClass(panel)!, #selector(NSWindow.setFrameOrigin(_:)), #selector(NSWindow.cua_overlayFixtureOrigin(_:)))
        exchange(object_getClass(panel)!, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.cua_overlayFixtureFront))
        exchange(object_getClass(panel)!, #selector(getter: NSWindow.isVisible), #selector(NSWindow.cua_overlayFixtureVisible))
    }
    static func verify(overlay: EventStreamRecordingOverlay, panel: NSPanel, startedAt: Date,
                       check: (String, Bool) -> Void) {
        guard let screen = NSScreen.screens.first else {
            check("screen-choice fixture has an owned display reference", false)
            return
        }
        self.screen = screen
        self.panel = panel
        suppressedFrontCalls = 0
        let frame = screen.frame
        // Expected screen choices. Only screen providers and the
        // owned panel's placement/presentation are controlled in this test.
        let fixtures: [(String, Bool, Bool, NSPoint, Bool)] = [
            ("empty-no-main", false, false, frame.origin, false),
            ("empty-with-main", false, true, frame.origin, true),
            ("inside-no-main", true, false, NSPoint(x: frame.midX, y: frame.midY), true),
            ("outside-no-main", true, false, NSPoint(x: frame.maxX + 100, y: frame.maxY + 100), false),
            ("outside-with-main", true, true, NSPoint(x: frame.maxX + 100, y: frame.maxY + 100), true),
            ("inside-with-main", true, true, NSPoint(x: frame.midX, y: frame.midY), true),
            ("max-edge-no-main", true, false, NSPoint(x: frame.maxX, y: frame.maxY), false),
            ("min-edge-no-main", true, false, frame.origin, true),
        ]
        toggle()
        defer { toggle(); self.panel = nil; self.screen = nil }
        for (name, screens, main, point, expected) in fixtures {
            screensPresent = screens
            mainPresent = main
            mouse = point
            requested = nil
            precondition(NSScreen.screens.count == (screens ? 1 : 0))
            precondition((NSScreen.main != nil) == main && NSEvent.mouseLocation == point)
            overlay.show(startedAt: startedAt)
            overlay.hide()
            check("screen choice: " + name, (requested != nil) == expected)
        }
        // A moving pointer must be sampled once before the screen scan,
        // including in the empty-screen branch.
        for count in [2, 3, 0] {
            screensPresent = count > 0
            copies = count
            mainPresent = count == 0
            mouse = NSPoint(x: frame.maxX + 100, y: frame.maxY + 100)
            followingMouse = NSPoint(x: frame.midX, y: frame.midY)
            mouseReads = 0
            requested = nil
            overlay.show(startedAt: startedAt)
            overlay.hide()
            check("single mouse snapshot with screen count " + String(count),
                  mouseReads == 1 && (requested != nil) == (count == 0))
        }
        followingMouse = nil
        copies = 1
        // Expected screen-change outcomes. The panel is
        // actually hidden; only its owned visibility getter is controlled.
        let updates: [(String, Bool, Bool, Bool, Bool)] = [
            ("empty-main", false, true, true, false),
            ("empty-no-main", false, false, true, false),
            ("one-no-main", true, false, true, true),
            ("one-main", true, true, true, true),
            ("hidden", true, true, false, false),
        ]
        for (name, screens, main, visible, expected) in updates {
            screensPresent = screens
            mainPresent = main
            visibleOverride = visible
            requested = nil
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification,
                                            object: NSApplication.shared)
            check("screen change: " + name, (requested != nil) == expected)
        }
        visibleOverride = nil
        precondition(suppressedFrontCalls == fixtures.count + 3 && !panel.isVisible)
    }
}

private extension NSScreen {
    @objc class func cua_overlayFixtureScreens() -> [NSScreen] {
        MainActor.assumeIsolated { RecordingOverlayScreenChoice.screensPresent ? Array(repeating: RecordingOverlayScreenChoice.screen!, count: RecordingOverlayScreenChoice.copies) : [] }
    }
    @objc class func cua_overlayFixtureMain() -> NSScreen? {
        MainActor.assumeIsolated { RecordingOverlayScreenChoice.mainPresent ? RecordingOverlayScreenChoice.screen : nil }
    }
}
private extension NSEvent {
    @objc class func cua_overlayFixtureMouse() -> NSPoint {
        MainActor.assumeIsolated {
            let point = RecordingOverlayScreenChoice.mouseReads == 0 ? RecordingOverlayScreenChoice.mouse
                : (RecordingOverlayScreenChoice.followingMouse ?? RecordingOverlayScreenChoice.mouse)
            RecordingOverlayScreenChoice.mouseReads += 1
            return point
        }
    }
}
private extension NSWindow {
    @objc func cua_overlayFixtureVisible() -> Bool {
        let owned = MainActor.assumeIsolated { () -> Bool? in
            self === RecordingOverlayScreenChoice.panel ? RecordingOverlayScreenChoice.visibleOverride : nil
        }
        return owned ?? cua_overlayFixtureVisible()
    }
    @objc func cua_overlayFixtureOrigin(_ point: NSPoint) {
        let owned = MainActor.assumeIsolated { () -> Bool in
            guard self === RecordingOverlayScreenChoice.panel else { return false }
            RecordingOverlayScreenChoice.requested = point
            return true
        }
        if !owned { cua_overlayFixtureOrigin(point) }
    }
    @objc func cua_overlayFixtureFront() {
        let owned = MainActor.assumeIsolated { () -> Bool in
            guard self === RecordingOverlayScreenChoice.panel else { return false }
            RecordingOverlayScreenChoice.suppressedFrontCalls += 1
            return true
        }
        if !owned { cua_overlayFixtureFront() }
    }
}
