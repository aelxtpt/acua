import AppKit
import ApplicationServices

enum AXPointerTarget {
    struct Resolved {
        let pointer: PointerTarget
        let element: AXUIElement?
        let cursorWindowID: UInt32
        let menu: AXUIElement?
        init(pointer: PointerTarget, element: AXUIElement?, cursorWindowID: UInt32, menu: AXUIElement? = nil) {
            self.pointer = pointer; self.element = element; self.cursorWindowID = cursorWindowID; self.menu = menu
        }
    }
    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = AX.point(element, kAXPositionAttribute as String), let s = AX.size(element, kAXSizeAttribute as String) else { return nil }
        let result = CGRect(origin: p, size: s)
        return CaptureLayout.valid(result) ? result : nil
    }
    private static func nativeFrame(_ element: AXUIElement) -> CGRect? {
        if let frame = AX.rectangle(element, "AXFrame") { return CaptureLayout.valid(frame) ? frame : nil }
        return frame(element)
    }
    private static func walk(_ element: AXUIElement, until visit: (AXUIElement) throws -> Bool) throws {
        for node in AXParentChain(start: element, parent: { AX.axElement(AX.copy($0, kAXParentAttribute as String)) }) {
            try RequestRuntime.check()
            if try visit(node) { return }
        }
    }
    private static func kind(_ pid: Int32) -> MouseTargeting.ProcessKind {
        guard let app = NSRunningApplication(processIdentifier: pid), app.isFinishedLaunching else { return .unavailable }
        return app.activationPolicy == .prohibited ? .service : .application
    }
    private static func remoteContext(_ element: AXUIElement, hostPID: Int32) throws -> (element: AXUIElement, pid: Int32)? {
        var context: (element: AXUIElement, pid: Int32, kind: MouseTargeting.ProcessKind)?
        try walk(element) { parent in
            guard let pid = try? AccessibilityWindowSPI.actualPID(parent) else { return false }
            let type = kind(pid)
            guard type != .unavailable else { return false }
            context = (parent, pid, type)
            return true
        }
        guard let context, let pid = MouseTargeting.remotePID(hostPID: hostPID, ancestry: [(context.pid, context.kind)]) else { return nil }
        return (context.element, pid)
    }
    // Keyboard targeting uses the live focused element and the same process-ancestry
    // policy as pointer targeting, without requiring a WindowServer window.
    static func keyboardPID(focusedElement: AXUIElement?, hostPID: Int32) throws -> Int32 {
        guard let focusedElement else { return hostPID }
        return try remoteContext(focusedElement, hostPID: hostPID)?.pid ?? hostPID
    }
    private static func remoteTarget(_ element: AXUIElement, hostPID: Int32) throws -> PointerTarget? {
        guard let context = try remoteContext(element, hostPID: hostPID) else { return nil }
        let pid = context.pid
        // Check self/parents for a usable window ID and
        // stops at a window/sheet boundary instead of guessing another window.
        var target: PointerTarget?
        try walk(context.element) { parent in
            if let id = try? AccessibilityWindowSPI.windowID(parent) {
                guard let record = Capture.windowDescription(id),
                      let owner = (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, owner > 0,
                      let bounds = Capture.currentFrame(windowID: id, pid: owner, requireOnscreen: false) else {
                    throw ServiceError(.accessibilityError, "Hosted target window metadata is unavailable")
                }
                // Keep the first actual service window ID, including hidden
                // backing windows, rather than substituting its visible host.
                target = PointerTarget(windowID: id, ownerPID: owner, screenFrame: bounds, eventPID: pid, requireOnscreen: false)
                return true
            }
            return [kAXWindowRole as String, kAXSheetRole as String].contains(AX.string(parent, kAXRoleAttribute as String) ?? "")
        }
        if let target { return target }
        throw ServiceError(.accessibilityError, "Hosted view has no resolvable target window")
    }

    static func frontWindowID(at point: CGPoint) -> UInt32? {
        let lookup = { () -> UInt32? in
            guard let appKitPoint = MouseTargeting.appKitPoint(from: point, screenFrames: NSScreen.screens.map(\.frame)) else { return nil }
            let number = NSWindow.windowNumber(at: appKitPoint, belowWindowWithWindowNumber: 0)
            guard number > 0 else { return nil }
            return UInt32(exactly: number)
        }
        return Thread.isMainThread ? lookup() : DispatchQueue.main.sync(execute: lookup)
    }

    private static func hitTest(_ root: AXUIElement, x: Float, y: Float) throws -> AXUIElement? {
        try RequestRuntime.check()
        AXUIElementSetMessagingTimeout(root, 1)
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(root, x, y, &hit)
        guard error == .success || error == .illegalArgument else {
            throw ServiceError(.accessibilityError, "Could not hit-test the pointer target (\(error.rawValue))")
        }
        try RequestRuntime.check()
        return error == .success ? hit : nil
    }

    private static func refinedTarget(_ hit: AXUIElement, hostPID: Int32) throws -> PointerTarget {
        if let remote = try remoteTarget(hit, hostPID: hostPID) { return remote }
        // Find the first ancestor belonging to the host.
        // A regular external app is not a view service and cannot donate a window.
        var result: PointerTarget?
        try walk(hit) { ancestor in
            guard (try? AccessibilityWindowSPI.actualPID(ancestor)) == hostPID else { return false }
            let id = try AccessibilityWindowSPI.windowID(ancestor)
            guard let bounds = Capture.currentFrame(windowID: id, pid: hostPID) else {
                throw ServiceError(.accessibilityError, "Refined pointer window is no longer onscreen")
            }
            result = PointerTarget(windowID: id, ownerPID: hostPID, screenFrame: bounds)
            return true
        }
        guard let result else { throw ServiceError(.accessibilityError, "Pointer hit has no window belonging to the requested app") }
        return result
    }

    static func resolve(at point: CGPoint, hostPID: Int32) throws -> PointerTarget {
        try resolveContext(at: point, hostPID: hostPID, registered: false).pointer
    }

    static func resolveContext(at point: CGPoint, hostPID: Int32, registered: Bool = true) throws -> Resolved {
        try RequestRuntime.check()
        let x = Float(point.x), y = Float(point.y)
        if !registered, !x.isFinite || !y.isFinite { throw ServiceError(.unhandledEvent, "Pointer position exceeds accessibility range") }
        let app = AXUIElementCreateApplication(hostPID)
        AXUIElementSetMessagingTimeout(app, 1)
        // The menu session seeds the primary window and sheets; subsequent native
        // window notifications update that registry. Ordering covers only
        // registered entries, not every AX window that happens to exist now.
        let records = registered ? AXMenuSessions.pointerWindows(pid: hostPID) : []
        var windows = records.map { $0.element }
        if !registered {
            windows = (AX.copy(app, kAXWindowsAttribute as String) as? [AnyObject])?.compactMap(AX.axElement) ?? []
            for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let window = AX.axElement(AX.copy(app, attribute as String)), !windows.contains(where: { CFEqual($0, window) }) { windows.append(window) }
            }
        }
        let ordered = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let ids = ordered.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
        // An empty ordered registry is rejected before any app hit.
        // An existing window whose frame misses the point is a different error.
        if registered, !records.contains(where: { ids.contains($0.id) }) {
            throw MouseTargeting.Failure.noWindowsAvailable
        }
        let legacyHit = registered ? nil : try hitTest(app, x: x, y: y)
        if let legacyHit, let window = try AX.window(of: legacyHit), !windows.contains(where: { CFEqual($0, window) }) { windows.append(window) }
        var candidates: [MouseTargeting.Window] = []
        for window in windows {
            try RequestRuntime.check()
            let id = registered ? records.first(where: { CFEqual($0.element, window) })?.id : (try? AccessibilityWindowSPI.windowID(window))
            guard let bounds = registered ? nativeFrame(window) : frame(window), let id,
                  let pid = try? AccessibilityWindowSPI.actualPID(window),
                  let screenFrame = Capture.currentFrame(windowID: id, pid: pid) else { continue }
            candidates.append(.init(id: id, pid: pid, frame: bounds, screenFrame: screenFrame))
        }
        let selected = try MouseTargeting.select(at: point, orderedIDs: ids, windows: candidates, nativeErrors: registered)
        let menu = records.first(where: { $0.id == selected.id && $0.isMenu })?.element
        // Query the app-local element only after a containing registered
        // window exists.
        let hit = registered ? try hitTest(app, x: x, y: y) : legacyHit
        var provisional = Resolved(pointer: selected.pointer, element: hit, cursorWindowID: selected.id, menu: menu)
        if selected.pid == hostPID, let hit {
            let effective = AX.children(hit).first ?? hit
            if let remote = try remoteTarget(effective, hostPID: hostPID) {
                // Clear the app-local hit for this backing-window
                // fallback. A later successful system-wide hit replaces it.
                provisional = Resolved(pointer: remote, element: nil, cursorWindowID: selected.id, menu: menu)
            }
        } else if selected.pid != hostPID {
            provisional = Resolved(pointer: selected.pointer, element: nil, cursorWindowID: selected.id, menu: menu)
        }
        let result = try MouseTargeting.refine(provisional: provisional, selectedWindowID: selected.id,
            frontWindowID: frontWindowID(at: point),
            hitTest: { try hitTest(AXUIElementCreateSystemWide(), x: x, y: y) },
            resolve: { Resolved(pointer: try refinedTarget($0, hostPID: hostPID), element: $0, cursorWindowID: selected.id, menu: menu) })
        try RequestRuntime.check()
        try requireCurrent(result.pointer)
        return result
    }

    static func forElement(_ element: AXUIElement, hostPID: Int32) throws -> PointerTarget {
        if let remote = try remoteTarget(element, hostPID: hostPID) { return remote }
        guard let window = try AX.window(of: element), let bounds = frame(window) else {
            throw ServiceError(.accessibilityError, "Control has no valid target window")
        }
        let id = try AccessibilityWindowSPI.windowID(window), pid = try AccessibilityWindowSPI.actualPID(window)
        let target = PointerTarget(windowID: id, ownerPID: pid, screenFrame: bounds)
        try requireCurrent(target)
        return target
    }
    static func requireCurrent(_ target: PointerTarget) throws {
        guard let current = Capture.currentFrame(windowID: target.windowID, pid: target.ownerPID, requireOnscreen: target.requireOnscreen),
              ScreenshotGeometry.framesMatch(current, target.screenFrame) else {
            throw ServiceError(.accessibilityError, "Pointer target moved, resized or closed; read app state again")
        }
    }
}
