import AppKit

@main
enum InputFixture {
    static var directory: URL!
    static var monitor: Any?
    static var activationMonitor: Any?
    static var revealObserver: NSObjectProtocol?
    static var focusPanel: NSPanel?
    final class FocusPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
    final class FailingPressButton: NSButton {
        override func accessibilityPerformPress() -> Bool {
            write(["event": "failed-press-attempt", "generation": tag])
            if tag == 9002 { performClick(nil) }
            return false
        }
    }
    static let initial = "🙂 início cafe\u{301} / primeiro alvo / segundo alvo fim 👩🏽‍💻"
    static func write(_ object: [String: Any]) {
        let url = directory.appendingPathComponent("events.jsonl")
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let file = try! FileHandle(forWritingTo: url)
        try! file.seekToEnd(); try! file.write(contentsOf: data); try! file.close()
    }
    final class Controller: NSObject {
        @objc func clicked(_ sender: NSButton) {
            InputFixture.write(["event": "button-action", "generation": sender.tag, "attached": sender.window != nil])
        }
        @objc func menuAction(_ sender: NSMenuItem) {
            InputFixture.write(["event": "menu-action", "item": sender.tag, "title": sender.title])
        }
    }
    static func main() {
        directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // Programmatic apps have no nib-provided Edit menu. Install the normal
        // responder-chain shortcut rather than assuming NSTextView handles Cmd-A.
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        appItem.submenu = NSMenu(title: "Fixture")
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let controller = Controller()
        let ownedItem = NSMenuItem(title: "Owned Actions", action: nil, keyEquivalent: "")
        let ownedMenu = NSMenu(title: "Owned Actions")
        let run = NSMenuItem(title: "Run owned action", action: #selector(Controller.menuAction(_:)), keyEquivalent: "")
        run.target = controller; run.tag = 1
        ownedMenu.addItem(run)
        let disabled = NSMenuItem(title: "Disabled owned action", action: #selector(Controller.menuAction(_:)), keyEquivalent: "")
        disabled.target = controller; disabled.tag = 3; disabled.isEnabled = false
        ownedMenu.autoenablesItems = false
        ownedMenu.addItem(disabled)
        let nested = NSMenuItem(title: "Nested actions", action: nil, keyEquivalent: "")
        let nestedMenu = NSMenu(title: "Nested actions")
        let nestedRun = NSMenuItem(title: "Run nested action", action: #selector(Controller.menuAction(_:)), keyEquivalent: "")
        nestedRun.target = controller; nestedRun.tag = 2
        nestedMenu.addItem(nestedRun); nested.submenu = nestedMenu
        ownedMenu.addItem(nested)
        ownedItem.submenu = ownedMenu; menu.addItem(ownedItem)
        app.mainMenu = menu
        let window = NSWindow(contentRect: CGRect(x: 250, y: 220, width: 640, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CUA input target"
        let editor = NSTextView(frame: CGRect(x: 20, y: 40, width: 600, height: 230))
        editor.string = initial
        editor.font = NSFont.systemFont(ofSize: 16)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.setAccessibilityIdentifier("input-editor")
        window.contentView!.addSubview(editor)
        var button = NSButton(title: "Input target", target: controller, action: #selector(Controller.clicked(_:)))
        var retired: [NSButton] = []
        button.frame = CGRect(x: 240, y: 330, width: 150, height: 35)
        button.bezelStyle = .rounded
        button.setAccessibilityIdentifier("input-button")
        window.contentView!.addSubview(button)
        var faultButtons: [FailingPressButton] = []
        if ProcessInfo.processInfo.environment["CUA_NATIVE_FAULT_BUTTONS"] == "1" {
            for (row, tag) in [9001, 9002].enumerated() {
                let fault = FailingPressButton(title: "Failing press \(tag)", target: controller, action: #selector(Controller.clicked(_:)))
                fault.frame = CGRect(x: 430, y: 320 + row * 40, width: 170, height: 35)
                fault.bezelStyle = .rounded; fault.tag = tag
                fault.setAccessibilityIdentifier("failing-press-\(tag)")
                fault.setAccessibilityHelp("cannotComplete")
                faultButtons.append(fault)
                window.contentView!.addSubview(fault)
            }
        }
        let scrollView = NSScrollView(frame: CGRect(x: 20, y: 420, width: 260, height: 160))
        let document = NSView(frame: CGRect(x: 0, y: 0, width: 240, height: 750))
        let distant = NSButton(title: "Offscreen target", target: controller, action: #selector(Controller.clicked(_:)))
        distant.frame = CGRect(x: 30, y: 600, width: 170, height: 35)
        distant.setAccessibilityIdentifier("offscreen-button"); distant.tag = 100
        document.addSubview(distant)
        scrollView.documentView = document; scrollView.hasVerticalScroller = true
        scrollView.contentView.scroll(to: .zero)
        scrollView.contentView.postsBoundsChangedNotifications = true
        revealObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main) { _ in
            if document.visibleRect.contains(CGPoint(x: distant.frame.midX, y: distant.frame.midY)) {
                write(["event": "target-revealed", "moved": true])
            }
        }
        window.contentView!.addSubview(scrollView)
        let other = NSWindow(contentRect: CGRect(x: 80, y: 150, width: 400, height: 260),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.title = "CUA input decoy"
        let decoy = NSTextView(frame: CGRect(x: 20, y: 20, width: 360, height: 220))
        decoy.string = "DO NOT TOUCH"
        decoy.setAccessibilityIdentifier("decoy-editor")
        other.contentView!.addSubview(decoy)
        other.orderFront(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(editor)
        app.activate(ignoringOtherApps: true)
        if ProcessInfo.processInfo.environment["ACUA_TRACE_FIXTURE_FOCUS"] == "1" {
            activationMonitor = NSEvent.addLocalMonitorForEvents(matching: .appKitDefined) { event in
                write(["event":"activation-packet","type":event.type.rawValue,"subtype":event.subtype.rawValue,
                       "activeBefore":app.isActive,"keyBefore":app.keyWindow?.windowNumber ?? -1,
                       "frontmostPID":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
                DispatchQueue.main.async {
                    write(["event":"activation-settled","subtype":event.subtype.rawValue,"active":app.isActive,
                           "keyWindow":app.keyWindow?.windowNumber ?? -1,
                           "frontmostPID":NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
                }
                return event
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .keyDown, .keyUp, .flagsChanged]) { event in
            let keyboard = [.keyDown, .keyUp, .flagsChanged].contains(event.type)
            write(["event": "input", "type": event.type.rawValue, "window": event.windowNumber,
                   "flags": event.modifierFlags.rawValue, "clickCount": keyboard ? 0 : event.clickCount,
                   "keyCode": keyboard ? event.keyCode : 0, "timestamp": event.timestamp,
                   "characters": event.type == .keyDown || event.type == .keyUp ? (event.characters ?? "") : ""])
            return event
        }
        DispatchQueue.main.async {
            write(["event": "ready", "window": window.windowNumber])
        }
        let commandTimer = Timer(timeInterval: 0.02, repeats: true) { _ in
            let file = directory.appendingPathComponent("command")
            guard let command = try? String(contentsOf: file, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: file)
            if command.hasPrefix("press-status:") {
                let status = String(command.dropFirst("press-status:".count))
                guard ["cannotComplete", "attributeUnsupported", "failure", "actionUnsupported"].contains(status) else { return }
                for button in faultButtons { button.setAccessibilityHelp(status) }
                write(["event": "press-status-set", "status": status])
            }
            if command == "state" {
                let range = editor.selectedRange()
                write(["event": "state", "text": editor.string, "selection": [range.location, range.length],
                       "decoy": decoy.string, "keyWindow": app.keyWindow?.windowNumber ?? -1,
                       "isActive": app.isActive,
                       "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
            }
            if command == "raise-window" {
                window.orderFrontRegardless()
                write(["event": "window-raised", "window": window.windowNumber])
            }
            if command == "request-key-focus" {
                window.makeKeyAndOrderFront(nil)
                write(["event": "requested-key-focus", "window": window.windowNumber])
            }
            if command == "nonactivating-panel" {
                let panel = FocusPanel(contentRect: CGRect(x: 950, y: 200, width: 260, height: 180),
                    styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
                panel.title = "CUA nonactivating focus panel"
                panel.hidesOnDeactivate = false
                let text = NSTextView(frame: CGRect(x: 10, y: 10, width: 240, height: 150))
                text.string = "Panel focus fixture"
                panel.contentView!.addSubview(text)
                focusPanel = panel
                panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(text)
                write(["event": "nonactivating-panel", "window": panel.windowNumber])
            }
            if command == "close-panel" { focusPanel?.close(); focusPanel = nil; write(["event": "panel-closed"]) }
            if command == "reset" {
                editor.string = initial
                editor.setSelectedRange(NSRange(location: 0, length: 0))
                window.makeKeyAndOrderFront(nil); window.makeFirstResponder(editor)
                write(["event": "reset"])
            }
            if command == "focus-decoy" {
                other.makeKeyAndOrderFront(nil); other.makeFirstResponder(decoy)
                write(["event": "decoy-focused"])
            }
            if command == "deactivate" {
                app.deactivate()
                write(["event": "deactivated"])
            }
            if command.hasPrefix("foreign-key:"), let pid = Int32(command.dropFirst("foreign-key:".count)),
               NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.hasPrefix("test.acua.focus-fixture.") == true {
                for down in [true, false] {
                    let key = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: down)!
                    var text: [UniChar] = [0x71]
                    key.keyboardSetUnicodeString(stringLength: 1, unicodeString: &text)
                    key.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
                    key.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(pid))
                    key.postToPid(pid)
                }
                write(["event": "foreign-key-posted", "targetPID": pid])
            }
            if command == "external-intervention" {
                // External-process metadata through the real session tap. A
                // zero-delta wheel event exercises observation without a click
                // or text insertion. This is not physical-human-input proof.
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0)!
                event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(getpid()))
                event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(getpid()))
                event.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(window.windowNumber))
                let displayHeight = CGDisplayBounds(CGMainDisplayID()).height
                event.location = CGPoint(x: window.frame.midX, y: displayHeight - window.frame.midY)
                event.post(tap: .cghidEventTap)
                write(["event": "external-intervention", "pid": getpid(), "window": window.windowNumber,
                       "postedAt": Date().timeIntervalSince1970])
            }
            if command == "event-stream-text" {
                // A bounded recorder test owns this foreground fixture. Never
                // inject a global key if focus has moved to an unrelated app.
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), app.keyWindow === window else {
                    write(["event":"event-stream-text-refused"]); return
                }
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:down)!
                    event.flags = []
                    var characters = Array("á😀".utf16)
                    event.keyboardSetUnicodeString(stringLength:characters.count,unicodeString:&characters)
                    event.setIntegerValueField(.eventSourceUnixProcessID,value:Int64(getpid()))
                    event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(getpid()))
                    event.setIntegerValueField(CGEventField(rawValue:51)!,value:Int64(window.windowNumber))
                    event.post(tap:.cghidEventTap)
                }
                write(["event":"event-stream-text-posted"])
            }
            if command == "animate-title" {
                window.title = "CUA input changing 0"
                write(["event": "animation-started"])
                for step in 1...6 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(step) * 0.06) {
                        window.title = step == 6 ? "CUA input target" : "CUA input changing \(step)"
                        write(["event": step == 6 ? "animation-ended" : "animation-step", "step": step])
                    }
                }
            }
            if command == "replace-button" {
                let frame = button.frame.offsetBy(dx: 60, dy: 0), generation = button.tag + 1
                retired.append(button); button.removeFromSuperview()
                button = NSButton(title: "Input target", target: controller, action: #selector(Controller.clicked(_:)))
                button.frame = frame; button.bezelStyle = .rounded; button.tag = generation
                button.setAccessibilityIdentifier("input-button")
                window.contentView!.addSubview(button)
                write(["event": "button-replaced", "generation": generation])
            }
            if command == "insert-button" {
                let extra = NSButton(title: "Extra control", target: nil, action: nil)
                extra.frame = CGRect(x: 440, y: 330, width: 150, height: 35)
                extra.setAccessibilityIdentifier("extra-button")
                window.contentView!.addSubview(extra, positioned: .below, relativeTo: button)
                write(["event": "button-inserted"])
            }
            if command == "ambiguous-button" {
                retired.append(button); button.removeFromSuperview()
                for x: CGFloat in [80, 270] {
                    let duplicate = NSButton(title: "Input target", target: controller, action: #selector(Controller.clicked(_:)))
                    duplicate.frame = CGRect(x: x, y: 330, width: 150, height: 35)
                    duplicate.bezelStyle = .rounded
                    duplicate.setAccessibilityIdentifier("input-button")
                    window.contentView!.addSubview(duplicate)
                }
                write(["event": "button-ambiguous"])
            }
            if command == "quit" { app.terminate(nil) }
        }
        // Test commands must remain available while AppKit tracks a held
        // button, so intervention can be posted before the mouse is released.
        RunLoop.main.add(commandTimer, forMode: .common)
        withExtendedLifetime(controller) { app.run() }
    }
}
