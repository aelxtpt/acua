import AppKit

// A worst-case window for screenshot and result size: it fills the main
// screen's visible frame and is dense with labelled buttons over a noisy
// background that compresses poorly. Each button press is logged with its
// tag, so a test can check that a click at an image coordinate lands on the
// button drawn there.
@main
enum ScreenshotSizeFixture {
    static let columns = 16
    static let rows = 24
    static var directory: URL!

    static func write(_ object: [String: Any]) {
        let url = directory.appendingPathComponent("events.jsonl")
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let file = try! FileHandle(forWritingTo: url)
        try! file.seekToEnd()
        try! file.write(contentsOf: data)
        try! file.close()
    }

    final class Controller: NSObject {
        @objc func pressed(_ sender: NSButton) {
            ScreenshotSizeFixture.write(["event": "pressed", "tag": sender.tag])
        }
    }

    /// Deterministic per-pixel noise, so JPEG and PNG sizes are repeatable.
    final class NoiseView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            var seed: UInt32 = 0x2545F491
            let step: CGFloat = 4
            var y: CGFloat = 0
            while y < bounds.height {
                var x: CGFloat = 0
                while x < bounds.width {
                    seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
                    NSColor(calibratedRed: CGFloat(seed & 0xFF) / 255, green: CGFloat((seed >> 8) & 0xFF) / 255,
                            blue: CGFloat((seed >> 16) & 0xFF) / 255, alpha: 1).setFill()
                    NSRect(x: x, y: y, width: step, height: step).fill()
                    x += step
                }
                y += step
            }
        }
    }

    static func main() {
        directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let frame = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "CUA screenshot size target"
        window.setFrame(frame, display: true)

        let content = NoiseView(frame: CGRect(origin: .zero, size: window.contentLayoutRect.size))
        window.contentView = content

        let controller = Controller()
        let cellWidth = content.bounds.width / CGFloat(columns)
        let cellHeight = content.bounds.height / CGFloat(rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let tag = row * columns + column
                let button = NSButton(title: "Button \(tag)", target: controller, action: #selector(Controller.pressed(_:)))
                button.tag = tag
                button.bezelStyle = .push
                // Row 0 at the top, as in the screenshot.
                button.frame = CGRect(x: CGFloat(column) * cellWidth + 4,
                                      y: content.bounds.height - CGFloat(row + 1) * cellHeight + 4,
                                      width: cellWidth - 8, height: cellHeight - 8)
                content.addSubview(button)
            }
        }

        window.makeKeyAndOrderFront(nil)
        app.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            write(["event": "ready", "columns": columns, "rows": rows,
                   "contentWidth": content.bounds.width, "contentHeight": content.bounds.height,
                   "windowWidth": window.frame.width, "windowHeight": window.frame.height,
                   "backingScale": window.backingScaleFactor])
        }
        app.run()
    }
}
