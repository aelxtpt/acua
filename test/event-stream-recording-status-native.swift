import AppKit

// The view and controls are production code. Supply a disposable recording so
// the fixture never captures input, writes a session, or opens a conversation.
@MainActor enum EventStreamRecordingOwner {
    static var activeRecordingStatus: EventStreamSessionStatus? = .init(
        isRecording: true, sessionID: "owned", maxDurationSeconds: 1800)
    static var activeSessionID: String? { activeRecordingStatus?.sessionID }
    static var activeBlockedContext: EventStreamBlockedCaptureContext?
    static var observedApplications: [EventStreamObservedApplication] = []
    static func stopFromControls(discarded: Bool) -> String? {
        preconditionFailure("The fixture must not choose a finalization action")
    }
}

@main enum RecordingStatusFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            guard condition() else {
                FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
                exit(1)
            }
            print("PASS \(name)")
        }
        func viewTree(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { viewTree($0) }
        }
        func pump(_ duration: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(duration))
        }
        func colorImage(_ color: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 17, height: 17), flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }
        }

        let view = EventStreamRecordingStatusView(frame: NSRect(x: 0, y: 0, width: 180, height: 26))
        let symbolSize = NSSize(width: 15, height: 14)
        let empty = EventStreamRecordingStatusView.Layout(applicationCount: 0, symbolSize: symbolSize, overflowWidth: 0)
        let crowded = EventStreamRecordingStatusView.Layout(applicationCount: 8, symbolSize: symbolSize, overflowWidth: 22)
        check("the empty composition contains only the recording symbol and margins",
              empty.iconCount == 0 && empty.overflow == nil && empty.size == NSSize(width: 29, height: 17))
        check("the composition shows five icons and a thin-space overflow count",
              crowded.iconCount == 5 && crowded.overflow == "+\u{2009}3" && crowded.size.width == 124)
        check("17-point icons overlap by 5 points",
              crowded.applicationRect(at: 0, in: view.bounds).maxX -
              crowded.applicationRect(at: 1, in: view.bounds).minX == 5)

        let width = view.update(icons: [colorImage(.red), colorImage(.blue)])
        view.frame.size.width = width
        view.appearance = NSAppearance(named: .vibrantLight)
        func render() -> NSBitmapImageRep {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                preconditionFailure("Could not allocate a view bitmap")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        func pixel(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> NSColor {
            let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
            return bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))!.usingColorSpace(.deviceRGB)!
        }
        let resting = render()
        let overlap = pixel(resting, x: 22, y: 13)
        check("the newest app is painted on top of the older overlapping icon",
              overlap.redComponent > 0.9 && overlap.blueComponent < 0.1)
        view.isPressed = true
        let pressed = render()
        check("the pressed vibrant pill darkens its background",
              pixel(pressed, x: 4, y: 13).alphaComponent > pixel(resting, x: 4, y: 13).alphaComponent)
        check("the artwork view leaves hit testing to the status button", view.hitTest(NSPoint(x: 12, y: 12)) == nil)
        view.frame.size.width = view.update(icons: Array(repeating: colorImage(.blue), count: 8))
        let withOverflow = render()
        func hasInk(from minX: Int, through maxX: Int) -> Bool {
            (minX...maxX).contains { x in
                (7...19).contains { y in
                    pixel(withOverflow, x: CGFloat(x), y: CGFloat(y)).alphaComponent > 0.55
                }
            }
        }
        check("the overflow count is drawn beside the application icons", hasInk(from: 77, through: 93))
        let trailing = Int(view.bounds.width.rounded(.down)) - 7
        check("the recording glyph is drawn at the trailing edge", hasInk(from: trailing - 13, through: trailing))


        let controls = EventStreamRecordingControls { _, _ in
            preconditionFailure("The fixture must not hand off a real recording")
        }
        controls.refresh()
        pump(0.15)
        let button = app.windows.compactMap(\.contentView).flatMap(viewTree)
            .compactMap { $0 as? NSStatusBarButton }
            .first { $0.toolTip == "Record & Replay is recording your actions" }
        guard let button, let window = button.window else {
            check("recording controls expose the native status button", false)
            return
        }
        check("the status button uses manual menu handling", button.menu == nil && button.target === controls)

        let owned = EventStreamObservedApplication(id: "owned-status", name: "Owned", bundleIdentifier: nil,
            bundleURL: nil, executableURL: nil)
        EventStreamRecordingOwner.activeBlockedContext = .init(application: owned, normalizedURL: URL(string: "https://owned.example")!)
        controls.refreshWarning()
        pump(0.12)
        func warningIsVisible() -> Bool {
            app.windows.contains { popup in
                guard popup.isVisible, let content = popup.contentView else { return false }
                return viewTree(content).contains {
                    ($0 as? NSTextField)?.stringValue == "Recording Disallowed on owned.example"
                }
            }
        }
        check("the blocked-site warning uses the real status button as anchor", warningIsVisible())

        var shownMenus = 0
        var menuWasPressed = false
        let tracker = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: .main) { notification in
                MainActor.assumeIsolated {
                    shownMenus += 1
                    menuWasPressed = viewTree(button).compactMap { $0 as? EventStreamRecordingStatusView }
                        .first?.isPressed == true
                    if let menu = notification.object as? NSMenu {
                        DispatchQueue.main.async { menu.cancelTracking() }
                    }
                }
            }
        defer { NotificationCenter.default.removeObserver(tracker) }
        func clickStatusButton() {
            let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, subtype: 0, data1: 0, data2: 0)!
            app.postEvent(event, atStart: true)
            _ = app.nextEvent(matching: .applicationDefined, until: Date().addingTimeInterval(1), inMode: .default, dequeue: true)
            _ = button.sendAction(button.action, to: button.target)
        }
        clickStatusButton()
        pump(0.35)
        check("the first click dismisses the warning without opening the menu", !warningIsVisible() && shownMenus == 0)
        clickStatusButton()
        check("the next click opens the menu with the pressed drawing", shownMenus == 1 && menuWasPressed)
        check("closing the menu clears the pressed drawing",
              viewTree(button).compactMap { $0 as? EventStreamRecordingStatusView }.first?.isPressed == false)
        EventStreamRecordingOwner.activeRecordingStatus = nil
        controls.refresh()
    }
}
