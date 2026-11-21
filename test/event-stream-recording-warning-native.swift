import AppKit

@main enum WarningFixture {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let panel = NSPanel(contentRect: NSRect(x: 180, y: 400, width: 46, height: 26),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        guard let anchor = panel.contentView else { preconditionFailure("Missing owned anchor") }
        let warning = EventStreamRecordingWarningPopover()
        let owned = EventStreamObservedApplication(id: "owned-warning", name: "Owned Fixture",
            bundleIdentifier: nil, bundleURL: nil, executableURL: nil)
        let blocked = EventStreamBlockedCaptureContext(application: owned, normalizedURL: URL(string: "https://www.owned.example/path")!)
        let other = EventStreamBlockedCaptureContext(application: owned, normalizedURL: URL(string: "https://other.example")!)

        func labels(in view: NSView) -> [String] {
            let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
            return own + view.subviews.flatMap { labels(in: $0) }
        }
        func window(for host: String) -> NSWindow? {
            app.windows.first {
                $0.isVisible && ($0.contentView.map { labels(in: $0) } ?? []).contains("Recording Disallowed on " + host)
            }
        }
        func check(_ name: String, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            if !condition() {
                FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
                exit(1)
            }
            print("PASS \(name)")
        }
        warning.update(blocked, anchor: anchor)
        check("a native popover appears with the cleaned hostname") { window(for: "owned.example") != nil }
        check("the popover explains that actions will be excluded") {
            window(for: "owned.example")?.contentView.map { labels(in: $0) }.map {
                $0.contains("Actions on owned.example will be excluded from the recording.")
            } == true
        }
        warning.update(other, anchor: anchor)
        check("changing blocked URLs replaces a visible popover in place") {
            window(for: "other.example") != nil && window(for: "owned.example") == nil
        }
        warning.dismissIfShown()
        check("opening the controls menu can dismiss the visible warning") { window(for: "other.example") == nil }
        warning.update(other, anchor: anchor)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        check("the dismissed URL stays hidden on a repeat update") { window(for: "other.example") == nil }
        warning.reset()
        warning.update(other, anchor: anchor)
        check("the same URL warns again after a session reset") { window(for: "other.example") != nil }
        warning.update(nil, anchor: anchor)
        check("returning to allowed content closes the warning") { window(for: "other.example") == nil }
        warning.update(blocked, anchor: anchor)
        check("a cleared warning can reopen on the next blocked context") { window(for: "owned.example") != nil }
        if let popup = window(for: "owned.example") {
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: popup)
        }
        check("the warning closes when its window becomes key") { window(for: "owned.example") == nil }
    }
}
