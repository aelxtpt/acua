import AppKit
import ApplicationServices

struct AXSnapshot {
    let app: String
    let bundleIdentifier: String
    let text: String
    let windowOrigin: CGPoint
    let windowSize: CGSize
    let windowTitle: String
    let screenshotPath: String?
    let geometry: ScreenshotGeometry?
    let windowElement: AXUIElement?
    let processKey: String
    var revision: TreeRevision<AXReference>? = nil
    let appReference: IPCApp
    var native = false
    var nativeTree: NativeAutomationTree.Snapshot? = nil
    var invalidationMonitor: EventStreamTreeInvalidationMonitor?
}

enum AX {
    static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success else { return nil }
        return value
    }
    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        copy(element, attribute) as? String
    }
    static func axElement(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    static func children(_ element: AXUIElement) -> [AXUIElement] {
        guard let raw = copy(element, kAXChildrenAttribute as String) as? [AnyObject] else { return [] }
        return raw.compactMap { axElement($0) }
    }
    private static func axValue(_ value: AnyObject?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }
    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let raw = axValue(copy(element, attribute)) else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(raw, .cgPoint, &p) ? p : nil
    }
    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let raw = axValue(copy(element, attribute)) else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(raw, .cgSize, &s) ? s : nil
    }
    static func rectangle(_ element: AXUIElement, _ attribute: String) -> CGRect? {
        guard let raw = axValue(copy(element, attribute)) else { return nil }
        var rect = CGRect.zero
        return AXValueGetValue(raw, .cgRect, &rect) ? rect : nil
    }
    static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success, let list = names as? [String] else { return [] }
        return list
    }
}

extension AX {
    // AXUIElementRef wrappers dispatch self-process operations onto
    // the main thread, and keep remote/unknown-PID operations on the caller.
    static func onElement<Result>(_ element: AXUIElement, _ body: () throws -> Result) throws -> Result {
        if !Thread.isMainThread, (try? AccessibilityWindowSPI.actualPID(element)) == getpid() {
            return try RequestRuntime.onMainThread(body)
        }
        return try body()
    }

    static func requireTextSelectionSettable(_ element: AXUIElement) throws {
        try onElement(element) {
            var settable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success,
                  settable.boolValue else {
                throw ServiceError(.accessibilityError, "The element does not support setting its text selection")
            }
        }
    }

    static func secondaryActionDescriptions(_ element: AXUIElement) throws -> [EventStreamNodeAction] {
        try NativeAutomationTree.onMain {
            EventStreamNativeNode.construct(EventStreamNativeSnapshots().node(element)).actionDescriptions
        }
    }

    static func boundsForRange(_ element: AXUIElement, range: NSRange) -> CGRect? {
        try? onElement(element) {
            var range = CFRange(location: range.location, length: range.length)
            guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
            var value: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                             parameter, &value) == .success,
                  let value = axValue(value) else { return nil }
            var rect = CGRect.zero
            return AXValueGetValue(value, .cgRect, &rect) ? rect : nil
        }
    }

    static func primaryWindow(_ application: AXUIElement) -> AXUIElement? {
        axElement(copy(application, kAXFocusedWindowAttribute as String))
            ?? axElement(copy(application, kAXMainWindowAttribute as String))
            ?? (copy(application, kAXWindowsAttribute as String) as? [AnyObject])?.compactMap(axElement).last
    }

    static func window(of element: AXUIElement) throws -> AXUIElement? {
        try RequestRuntime.check()
        if string(element, kAXRoleAttribute as String) == kAXWindowRole as String { return element }
        if let window = axElement(copy(element, kAXWindowAttribute as String)) { return window }
        var parent = axElement(copy(element, kAXParentAttribute as String))
        var visited = Set<AXReference>()
        while let current = parent {
            try RequestRuntime.check()
            guard visited.insert(AXReference(element: current)).inserted else { return nil }
            if string(current, kAXRoleAttribute as String) == kAXWindowRole as String { return current }
            parent = axElement(copy(current, kAXParentAttribute as String))
        }
        return nil
    }
}

