import AppKit

/// Real AppKit paste recipients and a private clipboard backup/restore helper.
/// Clipboard snapshots stay inside the test's temporary directory, never stdout.
@main enum PasteFixture {
    struct Representation: Codable { let type: String; let data: Data }
    struct Snapshot: Codable { let count: Int; let items: [[Representation]] }
    static func snapshot() -> Snapshot {
        let pb = NSPasteboard.general
        return Snapshot(count: pb.changeCount, items: (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { Representation(type: type.rawValue, data: $0) } }
        })
    }
    @discardableResult static func put(_ items: [[Representation]]) -> Bool {
        let pb = NSPasteboard.general; pb.clearContents()
        return items.isEmpty || pb.writeObjects(items.map { values in
            let item = NSPasteboardItem()
            for value in values { item.setData(value.data, forType: .init(value.type)) }
            return item
        })
    }
    static var directory: URL!
    static func log(_ value: [String: Any]) {
        let url = directory.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let file = try! FileHandle(forWritingTo: url); try! file.seekToEnd()
        try! file.write(contentsOf: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])); try! file.close()
    }
    final class Editor: NSTextView {
        var delay: Double = 0, ignore = false, replacement: String?
        override func paste(_ sender: Any?) {
            PasteFixture.log(["event": "paste-begin", "types": NSPasteboard.general.types?.map(\.rawValue) ?? [], "time": ProcessInfo.processInfo.systemUptime])
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if !ignore { super.paste(sender) }
            if let replacement {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(replacement, forType: .string)
            }
            PasteFixture.log(["event": "paste-end", "text": string, "time": ProcessInfo.processInfo.systemUptime])
        }
    }
    static func main() throws {
        let args = CommandLine.arguments
        if args.count >= 3 && args[1] == "--clipboard-read" {
            try JSONEncoder().encode(snapshot()).write(to: URL(fileURLWithPath: args[2]), options: .atomic); return
        }
        if args.count >= 3 && args[1] == "--clipboard-write" {
            if args.count >= 4 && NSPasteboard.general.changeCount != Int(args[3]) { exit(3) }
            let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
            guard put(saved.items) else { exit(2) }; return
        }
        if args.count >= 3 && args[1] == "--clipboard-seed" {
            let token = args.count > 3 ? args[3] : "CUA paste sentinel"
            let values = [
                [Representation(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(token.utf8)),
                 Representation(type: "test.acua.binary", data: Data([0, 1, 0xff, 0, 0x80]))],
                [Representation(type: NSPasteboard.PasteboardType.html.rawValue, data: Data("<b>CUA sentinel</b>".utf8)),
                 Representation(type: NSPasteboard.PasteboardType.rtf.rawValue, data: Data(#"{\rtf1\ansi CUA sentinel}"#.utf8))]
            ]
            guard put(values) else { exit(2) }
            try JSONEncoder().encode(snapshot()).write(to: URL(fileURLWithPath: args[2]), options: .atomic); return
        }
        directory = URL(fileURLWithPath: args[1])
        let application = NSApplication.shared; application.setActivationPolicy(.regular)
        let menu = NSMenu(), applicationItem = NSMenuItem(), editItem = NSMenuItem()
        menu.addItem(applicationItem); applicationItem.submenu = NSMenu(title: "Fixture")
        menu.addItem(editItem); editItem.submenu = NSMenu(title: "Edit")
        editItem.submenu!.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        application.mainMenu = menu
        let offset = args.count > 2 ? Double(args[2]) ?? 0 : 0
        let window = NSWindow(contentRect: CGRect(x: 140 + offset, y: 200, width: 520, height: 350), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.animationBehavior = .none; window.title = "CUA paste fixture"
        let editor = Editor(frame: CGRect(x: 10, y: 10, width: 500, height: 320))
        editor.isRichText = true; editor.setAccessibilityIdentifier("paste-editor")
        editor.isAutomaticQuoteSubstitutionEnabled = false; editor.isAutomaticDashSubstitutionEnabled = false
        window.contentView!.addSubview(editor); window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
        application.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { log(["event": "ready"]) }
        _ = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in
            let commandFile = directory.appendingPathComponent("command.json")
            guard let data = try? Data(contentsOf: commandFile), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let id = value["id"] as? String else { return }
            try? FileManager.default.removeItem(at: commandFile)
            if value["operation"] as? String == "reset" {
                editor.string = ""; editor.isRichText = value["rich"] as? Bool ?? true
                editor.delay = value["delay"] as? Double ?? 0; editor.ignore = value["ignore"] as? Bool ?? false
                editor.replacement = value["replacement"] as? String
                window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
            }
            var bold = false, link = false, monospace = false
            if editor.textStorage!.length > 0 {
                editor.textStorage!.enumerateAttribute(.font, in: NSRange(location: 0, length: editor.textStorage!.length)) { value, _, _ in
                    if let font = value as? NSFont {
                        let traits = NSFontManager.shared.traits(of: font)
                        if traits.contains(.boldFontMask) { bold = true }
                        if traits.contains(.fixedPitchFontMask) { monospace = true }
                    }
                }
            }
            if editor.textStorage!.length > 0 {
                editor.textStorage!.enumerateAttribute(.link, in: NSRange(location: 0, length: editor.textStorage!.length)) { value, _, _ in
                    if value != nil { link = true }
                }
            }
            log(["event": "reply", "id": id, "text": editor.string, "bold": bold, "link": link, "monospace": monospace])
        }
        application.run()
    }
}
