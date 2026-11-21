import AppKit
import ApplicationServices

/// Exercises the production AX/WindowServer adapters with windows owned by this
/// process. It never posts keyboard/mouse events and does not capture screenshots.
@main enum NativeWindowTargetTests {
    static func main() {
        guard !Permissions.screenLocked() else {
            print("Native target metadata checks require an unlocked session so owned windows can be onscreen")
            exit(1)
        }
        guard Permissions.accessibilityGranted() else {
            print("Native target metadata checks require Accessibility permission")
            exit(1)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let parent = NSWindow(contentRect: CGRect(x: 160, y: 180, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        parent.title = "CUA native pointer metadata parent"
        let child = NSPanel(contentRect: CGRect(x: 210, y: 280, width: 110, height: 75), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        child.title = "CUA native pointer metadata child"; child.hidesOnDeactivate = false
        parent.isReleasedWhenClosed = false; child.isReleasedWhenClosed = false
        parent.animationBehavior = .none; child.animationBehavior = .none
        parent.addChildWindow(child, ordered: .above)
        parent.orderFrontRegardless(); child.orderFrontRegardless()
        app.activate(ignoringOtherApps: true)
        let parentID = UInt32(parent.windowNumber), childID = UInt32(child.windowNumber), pid = getpid()
        DispatchQueue.main.async {
            DispatchQueue.global(qos: .userInitiated).async {
                var passed = 0, status: Int32 = 0
                func check(_ name: String, _ value: Bool) throws {
                    guard value else { throw ServiceError(.accessibilityError, name) }
                    passed += 1; print("PASS \(name)")
                }
                func waitForWindowServer(_ name: String, _ condition: () -> Bool) throws {
                    let limit = ProcessInfo.processInfo.systemUptime + 3
                    while !condition() {
                        guard ProcessInfo.processInfo.systemUptime < limit else { throw ServiceError(.accessibilityError, name) }
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
                func bounds(_ id: UInt32) throws -> (frame: CGRect, window: AXUIElement) {
                    let limit = ProcessInfo.processInfo.systemUptime + 3
                    var matched: CGRect?, matchingSince = ProcessInfo.processInfo.systemUptime
                    repeat {
                        // WindowServer reports intermediate bounds during the
                        // opening animation. Wait for the actual AX/CG frames
                        // to agree before testing production stale-frame checks.
                        let root = AXUIElementCreateApplication(pid)
                        let windows = (AX.copy(root, kAXWindowsAttribute as String) as? [AnyObject])?.compactMap(AX.axElement) ?? []
                        let frame = Capture.currentFrame(windowID: id, pid: pid)
                        var selected = windows.first(where: { (try? AccessibilityWindowSPI.windowID($0)) == id })
                        // A visible borderless child panel need not be included
                        // in AXWindows. Obtain its raw AXWindow from an actual
                        // hit instead of requiring enumeration as a prerequisite
                        // for the production pointer-routing tests below.
                        if selected == nil, let frame {
                            var hit: AXUIElement?
                            if AXUIElementCopyElementAtPosition(root, Float(frame.midX), Float(frame.midY), &hit) == .success,
                               let hit {
                                let candidate = AX.axElement(AX.copy(hit, kAXWindowAttribute as String)) ?? hit
                                if (try? AccessibilityWindowSPI.windowID(candidate)) == id { selected = candidate }
                            }
                        }
                        if let window = selected,
                           let position = AX.point(window, kAXPositionAttribute as String),
                           let size = AX.size(window, kAXSizeAttribute as String),
                           let frame,
                           ScreenshotGeometry.framesMatch(frame, CGRect(origin: position, size: size)) {
                            if matched == frame {
                                if ProcessInfo.processInfo.systemUptime - matchingSince >= 0.2 { return (frame, window) }
                            } else { matched = frame; matchingSince = ProcessInfo.processInfo.systemUptime }
                        } else { matched = nil }
                        Thread.sleep(forTimeInterval: 0.01)
                    } while ProcessInfo.processInfo.systemUptime < limit
                    throw ServiceError(.accessibilityError, "Owned native window did not reach matching AX/CG bounds within three seconds")
                }
                do {
                    try check("both private window APIs resolve", AccessibilityWindowSPI.available)
                    let axApp = AXUIElementCreateApplication(pid)
                    AXUIElementSetMessagingTimeout(axApp, 1)
                    try check("actual PID API returns this process", try AccessibilityWindowSPI.actualPID(axApp) == pid)
                    let childWindow = try bounds(childID), parentWindow = try bounds(parentID)
                    let childFrame = childWindow.frame, parentFrame = parentWindow.frame
                    let captureChild = try Capture.nativeWindowTarget(childWindow.window, appPID: pid)
                    let captureParent = try Capture.nativeWindowTarget(parentWindow.window, appPID: pid)
                    try check("native capture binds both AX windows to their WindowServer identities",
                              captureChild.windowID == childID && captureChild.ownerPID == pid && captureChild.screenFrame == childFrame &&
                              captureParent.windowID == parentID && captureParent.ownerPID == pid && captureParent.screenFrame == parentFrame)
                    let point = CGPoint(x: childFrame.midX, y: childFrame.midY)
                    try check("native mouse-hit lookup agrees with child ID", AXPointerTarget.frontWindowID(at: point) == childID)
                    let childTarget = try AXPointerTarget.resolve(at: point, hostPID: pid)
                    try check("real child AX target has the native WindowServer ID", childTarget.windowID == childID && childTarget.ownerPID == pid)
                    try check("real child target uses its own event-coordinate bounds", ScreenshotGeometry.framesMatch(childTarget.screenFrame, childFrame))
                    let parentPoint = CGPoint(x: parentFrame.maxX - 30, y: parentFrame.maxY - 30)
                    try check("native mouse-hit lookup agrees with uncovered parent", AXPointerTarget.frontWindowID(at: parentPoint) == parentID)
                    let parentTarget = try AXPointerTarget.resolve(at: parentPoint, hostPID: pid)
                    try check("point outside child targets the real parent", parentTarget.windowID == parentID)
                    var hit: AXUIElement?
                    let error = AXUIElementCopyElementAtPosition(axApp, Float(point.x), Float(point.y), &hit)
                    guard error == .success, let hit else { throw ServiceError(.accessibilityError, "Owned child hit test failed (\(error.rawValue))") }
                    let elementTarget = try AXPointerTarget.forElement(hit, hostPID: pid)
                    try check("element-based routing also resolves the child", elementTarget.windowID == childID)
                    DispatchQueue.main.sync { child.orderOut(nil) }
                    try waitForWindowServer("Child did not leave the onscreen window list") { Capture.currentFrame(windowID: childID, pid: pid) == nil }
                    let hiddenFrame = Capture.currentFrame(windowID: childID, pid: pid, requireOnscreen: false)
                    let hiddenAXID = try? AccessibilityWindowSPI.windowID(childWindow.window)
                    var hiddenTarget: PointerTarget?, hiddenError: ServiceError?
                    do { hiddenTarget = try Capture.nativeWindowTarget(childWindow.window, appPID: pid) }
                    catch { hiddenError = error as? ServiceError }
                    // Hiding this borderless panel can invalidate AXWindowID
                    // while WindowServer retains its raw description. Frame matching
                    // excludes getpid(), so an unresolved self-owned AX node must
                    // fail without borrowing its visible parent. CG metadata alone is not an AX ID.
                    if hiddenAXID == nil {
                        try check("hidden self-owned AX node without a window ID cannot borrow another capture target",
                                  hiddenTarget == nil && hiddenError?.code == .accessibilityError)
                    } else {
                        try check("a resolvable hidden AX window keeps its exact WindowServer identity",
                                  hiddenAXID == childID && hiddenTarget?.windowID == hiddenFrame.map { _ in childID } && hiddenTarget?.screenFrame == hiddenFrame)
                    }
                    do { try AXPointerTarget.requireCurrent(childTarget); throw ServiceError(.unknownError, "Hidden target was accepted") }
                    catch let error as ServiceError {
                        try check("hidden child fails target revalidation", error.code == .accessibilityError)
                    }
                    let afterHide = try AXPointerTarget.resolve(at: point, hostPID: pid)
                    try check("fresh target selection excludes the hidden child", afterHide.windowID == parentID)
                    DispatchQueue.main.sync { parent.setFrameOrigin(parent.frame.origin.applying(CGAffineTransform(translationX: 40, y: 20))) }
                    try waitForWindowServer("Parent move did not reach WindowServer") {
                        guard let current = Capture.currentFrame(windowID: parentID, pid: pid) else { return false }
                        return !ScreenshotGeometry.framesMatch(current, parentTarget.screenFrame)
                    }
                    do { try AXPointerTarget.requireCurrent(parentTarget); throw ServiceError(.unknownError, "Moved target was accepted") }
                    catch let error as ServiceError {
                        try check("moved parent fails target revalidation", error.code == .accessibilityError)
                    }
                    print("\(passed) native AX/window-target metadata checks passed; no input events or screenshot pixels tested")
                } catch {
                    print("NATIVE TARGET METADATA TEST DID NOT PASS after \(passed) checks: \(error)")
                    let root = AXUIElementCreateApplication(pid)
                    for window in (AX.copy(root, kAXWindowsAttribute as String) as? [AnyObject])?.compactMap(AX.axElement) ?? [] {
                        let id = try? AccessibilityWindowSPI.windowID(window)
                        print("AX WINDOW id=\(String(describing: id)) position=\(String(describing: AX.point(window, kAXPositionAttribute as String))) size=\(String(describing: AX.size(window, kAXSizeAttribute as String))) CG=\(String(describing: id.flatMap { Capture.currentFrame(windowID: $0, pid: pid) }))")
                    }
                    status = 1
                }
                DispatchQueue.main.async {
                    child.orderOut(nil); parent.removeChildWindow(child); child.close()
                    parent.orderOut(nil); parent.close()
                    exit(status)
                }
            }
        }
        app.run()
    }
}
