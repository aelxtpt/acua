import AppKit
import QuartzCore

@main enum CursorCaptureTests {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        var passed = 0
        func check(_ name: String, _ value: Bool) { precondition(value, name); passed += 1; print("PASS \(name)") }
        let cursor = CursorOverlay.shared
        defer { cursor.hide() }
        check("no overlay is selected before cursor creation", CursorCapture.visibleWindowID() == nil)
        cursor.prepare()
        check("warmup hidden window is excluded", CursorCapture.visibleWindowID() == nil)
        cursor.place(at: CGPoint(x: 200, y: 200), animated: false)
        let actual = CursorCapture.visibleWindowID()
        check("approved live cursor window is identified", actual != nil)
        let other = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        other.isOpaque = false; other.backgroundColor = .clear; other.hasShadow = false
        other.level = .screenSaver; other.ignoresMouseEvents = true; other.isReleasedWhenClosed = false
        let view = NSView(frame: other.contentView!.bounds)
        view.wantsLayer = true; let label = CALayer(); label.name = "otherOverlay"
        view.layer!.addSublayer(label); other.contentView = view
        other.orderFrontRegardless()
        defer { other.orderOut(nil); other.close() }
        check("unrelated service panel cannot replace the cursor", CursorCapture.visibleWindowID() == actual)
        label.name = "agentLabel"
        check("ambiguous matching panels fail instead of choosing the first", CursorCapture.visibleWindowID() == nil)
        other.orderOut(nil)
        check("removing ambiguity restores the actual cursor ID", CursorCapture.visibleWindowID() == actual)
        cursor.hide()
        check("hidden cursor is excluded after its window exists", CursorCapture.visibleWindowID() == nil)
        print("\(passed) native cursor-window lookup checks passed; screenshot pixels not tested")
    }
}
