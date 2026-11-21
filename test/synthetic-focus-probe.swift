import AppKit
import ApplicationServices

@main enum FocusProbe {
    static func main() throws {
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard CommandLine.arguments.count >= 3, let pid = Int32(CommandLine.arguments[2]),
              let app = NSRunningApplication(processIdentifier: pid),
              app.bundleIdentifier?.hasPrefix("test.acua.focus-fixture.") == true else {
            fatalError("Probe accepts only its disposable focus fixture")
        }
        let mode = CommandLine.arguments[1], ax = AXUIElementCreateApplication(pid)
        func value(_ attribute: String) -> CFTypeRef? {
            var v: CFTypeRef?; return AXUIElementCopyAttributeValue(ax, attribute as CFString, &v) == .success ? v : nil
        }
        if mode == "activate" { app.activate(options: []); return }
        if mode == "synthetic" {
            let windowID = UInt32(CommandLine.arguments[3])!
            let windows = value(kAXWindowsAttribute as String) as? [AXUIElement] ?? []
            let window = windows.first { w in
                var title: CFTypeRef?
                AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
                return (title as? String) == "CUA input target"
            }
            func point(_ attribute: String) -> CGPoint? {
                guard let window else { return nil }; var v: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, attribute as CFString, &v) == .success,
                      let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
                var p = CGPoint.zero
                return AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgPoint, &p) ? p : nil
            }
            var frame: CGRect?
            if let window, let origin = point(kAXPositionAttribute as String) {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &v) == .success,
                   let v, CFGetTypeID(v) == AXValueGetTypeID() {
                    var size = CGSize.zero
                    if AXValueGetValue(unsafeBitCast(v, to: AXValue.self), .cgSize, &size) { frame = CGRect(origin: origin, size: size) }
                }
            }
            let activationPoint = point("AXActivationPoint")
            FileHandle.standardError.write(Data("activationPoint=\(String(describing: activationPoint)) frame=\(String(describing: frame))\n".utf8))
            SyntheticFocusEvents.send(try SyntheticFocusEvents.activation(windowID: windowID, frame: frame,
                activationPoint: activationPoint), to: pid)
        } else if mode == "deactivate" {
            SyntheticFocusEvents.send(try SyntheticFocusEvents.deactivation(), to: pid)
        } else if mode == "key" {
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)!
                event.flags = .maskCommand; UserInteraction.markSynthesized(event); event.postToPid(pid)
            }
        }
        Thread.sleep(forTimeInterval: 0.15)
        let keyboard = KeyboardFocusSPI.observe()
        let result: [String: Any] = ["actualFrontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
            "keyboardFocusAvailable": KeyboardFocusSPI.available,
            "keyboardFocusPID": keyboard?.resolvedPID ?? -1,
            "keyboardQueryStatus": keyboard?.queryStatus ?? -1,
            "keyboardProcessStatus": keyboard?.processStatus ?? -1,
            "isActive": app.isActive, "axFrontmost": (value(kAXFrontmostAttribute as String) as? Bool) ?? false]
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
