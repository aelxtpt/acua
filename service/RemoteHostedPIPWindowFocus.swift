import AppKit
import ApplicationServices

@MainActor
final class RemoteHostedPIPWindowFocus {
    private struct Destination {
        let app: NSRunningApplication
        let windowID: CGWindowID?
    }

    private struct Window {
        let id: CGWindowID
        let pid: Int32
        let frame: CGRect?

        init?(_ info: [String: Any]) {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value else { return nil }
            self.id = id
            self.pid = pid
            frame = (info[kCGWindowBounds as String] as? [String: Any]).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        }
    }

    private let source: Destination
    private var restoreTarget: Destination?

    init?(windowID: CGWindowID, expectedPID: Int32?) {
        guard let owner = Self.window(windowID)?.pid, expectedPID == nil || expectedPID == owner,
              let app = NSRunningApplication(processIdentifier: owner), !app.isTerminated else { return nil }
        source = Destination(app: app, windowID: windowID)
    }

    func toggle() {
        guard let id = source.windowID, !source.app.isTerminated,
              Self.window(id)?.pid == source.app.processIdentifier else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let windows = Self.orderedWindows()
        let pid = source.app.processIdentifier
        if front?.processIdentifier == pid,
           Self.preferredWindows(pid: pid).contains(where: { Self.match($0, pid: pid, in: windows) == id })
              || Self.isFrontWindow(id, pid: pid, in: windows) {
            let destination = restoreTarget ?? Self.previousDestination(front: front, source: source, windows: windows)
            restoreTarget = nil
            if let destination { Self.focus(destination) }
        } else {
            restoreTarget = Self.previousDestination(front: front, source: source, windows: windows)
            Self.focus(source)
        }
    }

    private static func isFrontWindow(_ id: CGWindowID, pid: Int32, in windows: [Window]) -> Bool {
        // AppKit's nonmodal helper dialogs can appear above a document in the
        // WindowServer list without taking its focus.
        let auxiliaryIDs = Set(accessibilityWindows(pid: pid).compactMap { element -> CGWindowID? in
            guard value(element, kAXSubroleAttribute) as? String == kAXDialogSubrole,
                  value(element, kAXModalAttribute) as? Bool != true else { return nil }
            return match(element, pid: pid, in: windows)
        })
        return windows.first { $0.pid == pid && ($0.id == id || !auxiliaryIDs.contains($0.id)) }?.id == id
    }

    private static func previousDestination(front: NSRunningApplication?, source: Destination, windows: [Window]) -> Destination? {
        if let front, front.processIdentifier != getpid() {
            let pid = front.processIdentifier
            if let focused = preferredWindows(pid: pid).first,
               let id = match(focused, pid: pid, in: windows), id != source.windowID {
                return Destination(app: front, windowID: id)
            }
            if pid != source.app.processIdentifier { return Destination(app: front, windowID: nil) }
        }
        for window in windows where window.id != source.windowID && window.pid != getpid() {
            if let app = NSRunningApplication(processIdentifier: window.pid), app.activationPolicy == .regular {
                return Destination(app: app, windowID: window.id)
            }
        }
        return nil
    }

    private static func focus(_ destination: Destination) {
        let app = destination.app
        guard !app.isTerminated else { return }
        let pid = app.processIdentifier
        let id = destination.windowID.flatMap { window($0)?.pid == pid ? $0 : nil }
        if let processForPID = ApplicationRegistrySPI.processForPID,
           let setFrontProcess = ApplicationRegistrySPI.setFrontProcess {
            var process = ProcessSerialNumber()
            if processForPID(pid, &process) == 0 {
                _ = setFrontProcess(&process, id ?? 0, 0x100 | 0x200)
            }
        } else {
            _ = app.activate(options: [])
        }
        if let id,
           let target = accessibilityWindows(pid: pid).first(where: { (try? AccessibilityWindowSPI.windowID($0)) == id }) {
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        }
    }

    private static func window(_ id: CGWindowID) -> Window? {
        WindowDescription.lookup(id).flatMap(Window.init)
    }

    private static func orderedWindows() -> [Window] {
        let result = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        return result?.filter { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }.compactMap(Window.init) ?? []
    }

    private static func preferredWindows(pid: Int32) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let preferred = [kAXFocusedWindowAttribute, kAXMainWindowAttribute].compactMap { element(value(app, $0)) }
        if !preferred.isEmpty { return preferred }
        return Array((value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(1))
    }

    private static func accessibilityWindows(pid: Int32) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        return (value(app, kAXWindowsAttribute) as? [AXUIElement] ?? []) + preferredWindows(pid: pid)
    }

    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }

    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func match(_ element: AXUIElement, pid: Int32, in windows: [Window]) -> CGWindowID? {
        if let id = try? AccessibilityWindowSPI.windowID(element), window(id)?.pid == pid { return id }
        guard let position = value(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &dimensions) else { return nil }
        let matches = windows.filter { $0.pid == pid && $0.frame == CGRect(origin: origin, size: dimensions) }
        return matches.count == 1 ? matches.first?.id : nil
    }
}
