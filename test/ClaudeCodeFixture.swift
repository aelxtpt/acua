import AppKit

// A disposable app for the Claude Code end-to-end test: one window with a
// text field and a button. It logs what the agent did as JSON lines in
// <directory>/events.jsonl, so the test checks the effect, not the agent's
// own report of it.

@main
enum ClaudeCodeFixture {
    static var directory = URL(fileURLWithPath: "/tmp")

    static func write(_ event: [String: Any]) {
        let url = directory.appendingPathComponent("events.jsonl")
        guard var line = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]) else { return }
        line.append(0x0A)

        guard let handle = try? FileHandle(forWritingTo: url) else {
            try? line.write(to: url)
            return
        }

        handle.seekToEndOfFile()
        handle.write(line)
        try? handle.close()
    }

    final class Controller: NSObject, NSTextFieldDelegate {
        let field: NSTextField

        init(field: NSTextField) {
            self.field = field
        }

        @objc func pressed(_ sender: NSButton) {
            ClaudeCodeFixture.write(["event": "pressed", "text": field.stringValue])
        }

        func controlTextDidChange(_ notification: Notification) {
            ClaudeCodeFixture.write(["event": "text", "text": field.stringValue])
        }
    }

    static func main() {
        directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 420, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ACUA end-to-end fixture"

        let field = NSTextField(frame: NSRect(x: 20, y: 90, width: 380, height: 24))
        field.placeholderString = "Message"
        field.setAccessibilityLabel("Message")
        let controller = Controller(field: field)
        field.delegate = controller

        let button = NSButton(title: "Mark done", target: controller, action: #selector(Controller.pressed(_:)))
        button.frame = NSRect(x: 20, y: 30, width: 140, height: 32)

        window.contentView?.addSubview(field)
        window.contentView?.addSubview(button)
        window.makeKeyAndOrderFront(nil)
        app.activate()

        write(["event": "ready", "window": window.windowNumber])
        withExtendedLifetime(controller) { app.run() }
    }
}
