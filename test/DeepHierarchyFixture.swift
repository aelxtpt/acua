import AppKit

@main enum DeepHierarchyFixture {
    static var directory: URL!
    static var depth = 1
    static var clicks = 0
    static var groups: [NSAccessibilityElement] = []
    static var retired: [[NSAccessibilityElement]] = []
    static var window: NSWindow!
    static var root: Root!
    static var button: Button!
    static let controller = Controller()
    final class Root: NSView {
        var exposed: [Any] = []
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .group }
        override func accessibilityChildren() -> [Any]? { exposed }
    }
    final class Button: NSButton {
        weak var syntheticParent: AnyObject?
        override func accessibilityParent() -> Any? { syntheticParent ?? super.accessibilityParent() }
        // A virtual accessibility hierarchy may expose the owning window only
        // through its ancestry. It remains a real visible, clickable button.
        override func accessibilityWindow() -> Any? { nil }
    }
    final class Controller: NSObject {
        @objc func clicked(_ sender: Any?) {
            clicks += 1; write(["event": "button-action", "depth": depth, "count": clicks])
        }
    }
    static func write(_ object: [String: Any]) {
        let url = directory.appendingPathComponent("events.jsonl")
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let file = try! FileHandle(forWritingTo: url); try! file.seekToEnd(); try! file.write(contentsOf: data); try! file.close()
    }
    static func configure(_ count: Int) {
        retired.append(groups); groups = []; depth = count; clicks = 0
        let frame = window.convertToScreen(root.convert(root.bounds, to: nil))
        for index in 0..<count {
            let group = NSAccessibilityElement()
            group.setAccessibilityRole(.group); group.setAccessibilityLabel("Owned depth \(index)")
            group.setAccessibilityFrame(frame)
            group.setAccessibilityParent(index == 0 ? root : groups[index - 1])
            if let previous = groups.last { previous.setAccessibilityChildren([group]) }
            groups.append(group)
        }
        groups.last?.setAccessibilityChildren([button!])
        button.syntheticParent = groups.last ?? root
        root.exposed = groups.first.map { [$0] } ?? [button!]
        NSAccessibility.post(element: root!, notification: .layoutChanged)
        write(["event": "depth-ready", "depth": depth])
    }
    static func main() {
        directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        window = NSWindow(contentRect: CGRect(x: 240, y: 230, width: 560, height: 320), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CUA owned deep hierarchy"
        root = Root(frame: CGRect(x: 0, y: 0, width: 560, height: 320)); window.contentView = root
        button = Button(title: "Owned deep target", target: controller, action: #selector(Controller.clicked(_:)))
        button.frame = CGRect(x: 140, y: 130, width: 260, height: 45); button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("owned-deep-button"); root.addSubview(button)
        window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        configure(1)
        DispatchQueue.main.async { write(["event": "ready"]) }
        _ = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { _ in
            let url = directory.appendingPathComponent("command")
            guard let command = try? String(contentsOf: url, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: url)
            if command.hasPrefix("depth:"), let value = Int(command.dropFirst(6)), (0...512).contains(value) { configure(value) }
            if command == "state" { write(["event": "state", "depth": depth, "count": clicks]) }
        }
        app.run()
    }
}
