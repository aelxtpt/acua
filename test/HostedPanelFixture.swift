import AppKit
import UniformTypeIdentifiers

@main
enum HostedPanelFixture {
    static var directory: URL!
    static var window: NSWindow!
    static var other: NSWindow!
    static var editor: NSTextView!
    static var decoy: NSTextView!
    static var panel: NSOpenPanel?
    static var keyMonitor: Any?
    static let controller = Controller()
    static var file: URL { directory.appendingPathComponent("owned/owned-🙂-document.txt") }
    static func write(_ object: [String: Any]) {
        let url = directory.appendingPathComponent("events.jsonl")
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try! FileHandle(forWritingTo: url)
        try! handle.seekToEnd(); try! handle.write(contentsOf: data); try! handle.close()
    }
    final class Controller: NSObject, NSOpenSavePanelDelegate {
        @objc func open(_ sender: Any?) { present(sheet: true) }
        func panel(_ sender: Any, validate url: URL) throws {
            guard url.standardizedFileURL == file.standardizedFileURL else {
                throw NSError(domain: "OwnedPanelFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select only the owned fixture file"])
            }
        }
        func present(sheet: Bool) {
            guard HostedPanelFixture.panel == nil else { return }
            let picker = NSOpenPanel()
            picker.title = "CUA owned file chooser"
            picker.message = "Select the temporary owned fixture document"
            picker.prompt = "Select owned file"
            picker.directoryURL = file.deletingLastPathComponent()
            picker.allowedContentTypes = [.plainText]
            picker.canChooseFiles = true; picker.canChooseDirectories = false
            picker.allowsMultipleSelection = false; picker.showsHiddenFiles = false
            picker.delegate = self
            HostedPanelFixture.panel = picker
            let completed: (NSApplication.ModalResponse) -> Void = { response in
                let selected = picker.url?.standardizedFileURL
                write(["event": "panel-completed", "accepted": response == .OK,
                       "ownedSelection": selected == file.standardizedFileURL,
                       "editor": editor.string, "decoy": decoy.string])
                HostedPanelFixture.panel = nil
            }
            if sheet { picker.beginSheetModal(for: window, completionHandler: completed) }
            else { picker.begin(completionHandler: completed) }
            write(["event": "panel-requested", "sheet": sheet])
        }
    }
    static func main() {
        directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try! FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! "OWNED TEMPORARY TEST DOCUMENT".write(to: file, atomically: true, encoding: .utf8)
        try! "OWNED DECOY FILE".write(to: file.deletingLastPathComponent().appendingPathComponent("do-not-select.txt"), atomically: true, encoding: .utf8)
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let menu = NSMenu(); let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        app.mainMenu = menu
        window = NSWindow(contentRect: CGRect(x: 200, y: 150, width: 760, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CUA hosted chooser target"
        editor = NSTextView(frame: CGRect(x: 20, y: 20, width: 720, height: 430))
        editor.string = "OWNED HOST DOCUMENT — DO NOT EDIT"
        editor.setAccessibilityIdentifier("host-editor")
        window.contentView!.addSubview(editor)
        let open = NSButton(title: "Open owned chooser", target: controller, action: #selector(Controller.open(_:)))
        open.frame = CGRect(x: 240, y: 500, width: 240, height: 40); open.bezelStyle = .rounded
        open.setAccessibilityIdentifier("open-owned-chooser")
        window.contentView!.addSubview(open)
        other = NSWindow(contentRect: CGRect(x: 50, y: 120, width: 350, height: 240), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.title = "CUA hosted chooser decoy"
        decoy = NSTextView(frame: CGRect(x: 10, y: 10, width: 330, height: 220)); decoy.string = "DO NOT TOUCH HOSTED DECOY"
        other.contentView!.addSubview(decoy); other.orderFront(nil)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor); app.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            write(["event": "host-key", "type": event.type.rawValue, "keyCode": event.keyCode,
                   "window": event.windowNumber, "keyWindow": app.keyWindow?.windowNumber ?? -1,
                   "panelWindow": panel?.windowNumber ?? -1])
            return event
        }
        DispatchQueue.main.async { write(["event": "ready", "window": window.windowNumber]) }
        _ = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            let commandURL = directory.appendingPathComponent("command")
            guard let command = try? String(contentsOf: commandURL, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: commandURL)
            switch command {
            case "state":
                write(["event": "state", "editor": editor.string, "decoy": decoy.string,
                       "panelVisible": panel?.isVisible ?? false, "panelWindow": panel?.windowNumber ?? -1,
                       "attachedSheet": window.attachedSheet?.windowNumber ?? -1,
                       "keyWindow": app.keyWindow?.windowNumber ?? -1,
                       "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
            case "open-sheet": controller.present(sheet: true)
            case "open-panel": controller.present(sheet: false)
            case "cancel-panel": panel?.cancel(nil)
            case "focus-decoy":
                other.makeKeyAndOrderFront(nil); other.makeFirstResponder(decoy); write(["event": "decoy-focused"])
            case "focus-main":
                window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor); write(["event": "main-focused"])
            default: break
            }
        }
        app.run()
    }
}
