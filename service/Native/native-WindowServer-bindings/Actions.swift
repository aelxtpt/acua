import AppKit
import ApplicationServices
import Darwin

enum Actions {
    private static let clipboardLock = NSRecursiveLock()
    private static let cursorLock = NSLock()
    private static var cursorOwner: String?
    private static var cursorRevision = UUID()
    private static func cursor(for bundle: String, enabled: Bool? = nil, _ update: () -> Void) {
        // Element callers use the flag; coordinate preparation and retained
        // interaction callbacks pass an explicit value from their own phase.
        guard enabled ?? CursorCapture.enabled else { return }
        cursorLock.lock(); defer { cursorLock.unlock() }
        cursorOwner = bundle
        cursorRevision = UUID()
        update()
    }
    static func hideCursor(for bundle: String) {
        cursorLock.lock(); defer { cursorLock.unlock() }
        if cursorOwner == bundle { cursorOwner = nil; cursorRevision = UUID(); CursorOverlay.shared.hide() }
    }
    static func cursorForCapture(_ bundle: String) -> CursorCapture.Reference? {
        guard CursorCapture.enabled else { return nil }
        cursorLock.lock(); let owned = cursorOwner == bundle, revision = cursorRevision; cursorLock.unlock()
        guard owned else { return nil }
        let window = CursorCapture.visibleWindowID()
        // The main-thread lookup must not retain cursorLock: another action
        // may already hold it while waiting to update that same main thread.
        cursorLock.lock(); defer { cursorLock.unlock() }
        guard cursorOwner == bundle, cursorRevision == revision, let window else { return nil }
        return CursorCapture.Reference(windowID: window, revision: revision)
    }
    static func cursorIsCurrent(_ reference: CursorCapture.Reference, for bundle: String) -> Bool {
        cursorLock.lock(); defer { cursorLock.unlock() }
        return cursorOwner == bundle && cursorRevision == reference.revision
    }
    // WindowServerSPI.setWindowLocation takes (CGEvent, CGPoint).
    // CGEvent.location alone does not populate the window-relative event point.
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocation? = {
        ControllerWindowServerOperations.native.setLocation($0, $1)
    }
    // MARK: dispatch
    static func perform<Result>(app identifier: String, action: JSON, captureResult: Bool, native: Bool,
                                response: (IPCApp, AXSnapshot?) -> Result) throws -> Result {
        let supported = Set(["click", "drag", "paste", "performSecondaryAction", "pressKey", "scroll", "setValue", "selectText", "type"])
        guard action.count == 1, let name = action.keys.first, supported.contains(name), asDict(action[name]) != nil else {
            throw ServiceError(.couldNotGetRequestData, "Expected exactly one supported action")
        }
        if let type = asDict(action["type"]), str(type["_0"]) == nil {
            throw ServiceError(.couldNotGetRequestData, "type requires text")
        }
        if let value = asDict(action["setValue"]), str(value["value"]) == nil {
            throw ServiceError(.couldNotGetRequestData, "setValue requires a string value")
        }
        try NativeTargetPolicy.requireAllowed(identifier)
        let bundle = try AppResolver.require(identifier).bundleIdentifier
        try NativeTargetPolicy.requireAllowed(bundle)
        try AppSessions.shared.validateStart(bundle)
        try Permissions.requireUnlockedScreen()
        return try RequestRuntime.serialized(app: bundle) {
        let app = try AppResolver.require(bundle)
        let token = try AppSessions.shared.prepare(app: app.ipc, process: AXCapture.processKey(app), create: false)
        return try RequestRuntime.withCheckpoint({ try AppSessions.shared.check(token) }) {
        _ = try AppSessions.shared.activate(token)
        try RequestRuntime.check()
        try Permissions.requireAccessibility()
        try UserInteractionMonitor.shared.ensureRunning()
        if native { AXMenuSessions.observe(app, holdAccessibility: true) }
        try RequestRuntime.check()
        var polling: AXSettler.Polling = .applicationDefault
        if let a = asDict(action["click"]) { polling = try click(a, bundle: bundle, native: native) }
        else if let a = asDict(action["drag"]) { try drag(a, bundle: bundle, native: native) }
        else if let a = asDict(action["paste"]) { try paste(a, bundle: bundle, native: native); polling = .tenthSecond }
        else if let a = asDict(action["performSecondaryAction"]) { try secondary(a, bundle: bundle, native: native) }
        else if let a = asDict(action["pressKey"]) { try pressKey(a, bundle: bundle); polling = .tenthSecond }
        else if let a = asDict(action["scroll"]) { try scroll(a, bundle: bundle, native: native) }
        else if let a = asDict(action["setValue"]) { try setValue(a, bundle: bundle) }
        else if let a = asDict(action["selectText"]) { try selectText(a, bundle: bundle, native: native) }
        else if let a = asDict(action["type"]) { try typeText(str(a["_0"]) ?? "", bundle: bundle); polling = .tenthSecond }
        else { throw ServiceError(.unhandledEvent, "Unrecognized action") }
        let pid = app.running.processIdentifier
        var settled: AXSettledWindow?
        if native {
            if captureResult, name != "scroll" {
                try AppSessions.shared.exchangeSettling(false, for: token)
                settled = try AXSettler.waitForNativeCapture(app: app, polling: polling)
            } else if !captureResult, name != "paste" {
                try AppSessions.shared.exchangeSettling(true, for: token)
            }
        } else {
            try AXSettler.wait(app: AXUIElementCreateApplication(pid), pid: pid)
        }
        let snapshot = captureResult ? try AXCapture.captureCurrent(app: app, disableDiff: false, enforceURLPolicy: true,
                                                                    native: native, settled: settled) : nil
        return response(app.ipc, snapshot)
        }
        }
    }

    // MARK: helpers
    private static func point(from target: JSON, bundle: String) throws -> (point: CGPoint, geometry: ScreenshotGeometry, pointer: PointerTarget)? {
        if let coord = asDict(target["coordinate"]), let pair = array(coord["_0"]), pair.count == 2,
           let x = doubleValue(pair[0]), let y = doubleValue(pair[1]) {
            let geometry = try coordinateSnapshot(bundle).geometry!
            let point = try geometry.screenPoint(from: CGPoint(x: x, y: y))
            return (point, geometry, try AXPointerTarget.resolve(at: point, hostPID: geometry.ownerPID))
        }
        return nil
    }
    private static func element(from target: JSON, bundle: String, ignoreValueChange: Bool = false) throws -> AXUIElement? {
        guard let key = elementIndex(from: target) else { return nil }
        return try AXIndex.shared.element(key, for: bundle, ignoreValueChange: ignoreValueChange)
    }
    private static func elementIndex(from target: JSON) -> String? {
        asDict(target["elementID"]).flatMap { str($0["_0"]) } ?? str(target["elementID"])
    }
    private static func snapshot(_ bundle: String) -> AXSnapshot? { AXIndex.shared.snapshot(for: bundle) }

    private static func nativeCoordinatePoint(_ point: CGPoint, bundle: String) throws -> (point: CGPoint, hostPID: Int32) {
        let app = try AppResolver.require(bundle)
        guard let layout = AXIndex.shared.nativeCoordinates(for: bundle, processKey: AXCapture.processKey(app)) else {
            throw ServiceError(.noActiveSession, "Read get_app_state before using coordinates")
        }
        // Coordinates use controller state, including its initial null origin
        // and zero scale, independently from the latest image/window lifetime.
        return (layout.screenPoint(from: try NativeCoordinateConversion.truncate(point)), app.running.processIdentifier)
    }

    private static func coordinateSnapshot(_ bundle: String, raiseWindow: Bool = true) throws -> AXSnapshot {
        guard let snapshot = snapshot(bundle), let geometry = snapshot.geometry else {
            throw ServiceError(.noActiveSession, "Read get_app_state with a screenshot before using coordinates")
        }
        guard let app = AppResolver.resolve(bundle), app.running.processIdentifier == geometry.ownerPID,
              AXCapture.processKey(app) == snapshot.processKey,
              let current = Capture.currentFrame(windowID: geometry.windowID, pid: geometry.ownerPID),
              ScreenshotGeometry.framesMatch(current, geometry.screenFrame) else {
            throw ServiceError(.accessibilityError, "Captured window moved, resized or closed; read get_app_state again")
        }
        guard raiseWindow else { return snapshot }
        if let window = snapshot.windowElement {
            let result = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            guard result == .success || result == .actionUnsupported else {
                throw ServiceError(.accessibilityError, "Captured window is no longer available; read get_app_state again")
            }
        }
        guard let raisedFrame = Capture.currentFrame(windowID: geometry.windowID, pid: geometry.ownerPID),
              ScreenshotGeometry.framesMatch(raisedFrame, geometry.screenFrame) else {
            throw ServiceError(.accessibilityError, "Captured window changed while raising it; read get_app_state again")
        }
        return snapshot
    }

    private static func elementCenter(_ element: AXUIElement) -> CGPoint? {
        guard let p = AX.point(element, kAXPositionAttribute as String), let s = AX.size(element, kAXSizeAttribute as String) else { return nil }
        let frame = CGRect(origin: p, size: s)
        return ClickableGeometry.valid(frame) ? CGPoint(x: frame.midX, y: frame.midY) : nil
    }

    private static func focusedElementLocation(_ bundle: String) -> (point: CGPoint, windowID: CGWindowID?)? {
        guard let resolved = AppResolver.resolve(bundle) else { return nil }
        let app = AXUIElementCreateApplication(resolved.running.processIdentifier)
        guard let focused = AX.axElement(AX.copy(app, kAXFocusedUIElementAttribute as String)) else { return nil }
        guard let point = elementCenter(focused) ?? AX.point(focused, kAXPositionAttribute as String),
              point.x.isFinite, point.y.isFinite else { return nil }
        let windowID = (try? AX.window(of: focused)).flatMap { try? AccessibilityWindowSPI.windowID($0) }
        return (point, windowID)
    }

    private static func activate(_ bundle: String) {
        if let app = AppResolver.resolve(bundle) { app.running.activate(options: []) }
    }

    private static func keyboardPID(_ bundle: String, element: AXUIElement? = nil) throws -> pid_t {
        guard let app = AppResolver.resolve(bundle) else {
            throw ServiceError(.runningApplicationNotFound, "Application is no longer running")
        }
        let window = try element.flatMap { try AX.window(of: $0) } ?? snapshot(bundle)?.windowElement
        try SyntheticFocusSessions.enforce(app: app, window: window)
        if let element {
            let result = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if result != .success && (AX.copy(element, kAXFocusedAttribute as String) as? Bool) != true {
                throw ServiceError(.accessibilityError, "Could not focus the requested text field")
            }
        }
        try RequestRuntime.check()
        let application = AXUIElementCreateApplication(app.running.processIdentifier)
        let focused = AX.axElement(AX.copy(application, kAXFocusedUIElementAttribute as String))
        return try AXPointerTarget.keyboardPID(focusedElement: focused, hostPID: app.running.processIdentifier)
    }

    private static func keyboardEvent(code: CGKeyCode, down: Bool, flags: CGEventFlags, pid: pid_t,
                                      modifier: Bool = false, unicode: [UniChar]? = nil,
                                      willPost: ((CGEvent) -> Void)? = nil) throws {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else {
            throw ServiceError(.unhandledEvent, "Could not create keyboard event")
        }
        if modifier { event.type = .flagsChanged }
        event.flags = flags
        if var unicode { event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode) }
        UserInteraction.markSynthesized(event)
        willPost?(event)
        event.postToPid(pid)
    }

    private static func withHeldKeys<T>(_ chord: KeyChord?, pid: pid_t, body: (CGEventFlags) throws -> T) throws -> T {
        var held: [KeyChord.Modifier] = []
        var heldKey: CGKeyCode?
        let flags = chord?.flags ?? []
        let receipt: KeyboardReleaseDelivery?
        if chord != nil && FocusStealPreventer.hasKeyboardFilter(for: pid) {
            receipt = try KeyboardReleaseDelivery(pid: pid)
        } else { receipt = nil }
        defer { receipt?.close() }
        var released = false
        func release() throws {
            guard !released else { return }
            released = true
            var failure: Error?
            // Cleanup must run even when the request expired or the body failed.
            if let heldKey {
                do { try keyboardEvent(code: heldKey, down: false, flags: flags, pid: pid, willPost: receipt?.willPost) }
                catch { failure = error }
            }
            while let last = held.popLast() {
                let remaining = held.reduce(CGEventFlags()) { $0.union($1.flag) }
                do { try keyboardEvent(code: last.code, down: false, flags: remaining, pid: pid, modifier: true, willPost: receipt?.willPost) }
                catch { if failure == nil { failure = error } }
            }
            if receipt?.waitUntilDelivered() == false, failure == nil {
                failure = ServiceError(.accessibilityError, "Keyboard release did not pass the input filters")
            }
            if let failure { throw failure }
        }
        do {
            for modifier in chord?.modifiers ?? [] {
                try RequestRuntime.check()
                let current = held.reduce(modifier.flag) { $0.union($1.flag) }
                try keyboardEvent(code: modifier.code, down: true, flags: current, pid: pid, modifier: true)
                held.append(modifier)
            }
            if let key = chord?.key {
                try RequestRuntime.check()
                try keyboardEvent(code: key, down: true, flags: flags, pid: pid)
                heldKey = key
            }
            let result = try body(flags)
            try release()
            return result
        } catch { try? release(); throw error }
    }

    // MARK: actions
    private static func click(_ a: JSON, bundle: String, native: Bool) throws -> AXSettler.Polling {
        let options = try ClickOptions(a)
        if !native { activate(bundle) }
        if native, elementIndex(from: asDict(a["at"]) ?? [:]) != nil {
            return try nativeElementClick(a, bundle: bundle, options: options)
        }
        if native { return try nativeCoordinateClick(a, bundle: bundle, options: options) }
        if let el = try element(from: asDict(a["at"]) ?? [:], bundle: bundle) {
            let target = try AXClickableTarget.prepare(el, bundle: bundle) {
                guard let refreshed = try element(from: asDict(a["at"]) ?? [:], bundle: bundle) else {
                    throw ServiceError(.accessibilityError, "Control disappeared after scrolling")
                }
                return refreshed
            }
            cursor(for: bundle) {
                CursorOverlay.shared.place(at: target.point, targetWindowID: target.pointer.windowID)
                CursorOverlay.shared.press()
            }
            if options.canUseAXPress, AX.actionNames(target.element).contains(kAXPressAction as String),
               AXUIElementPerformAction(target.element, kAXPressAction as CFString) == .success {
                return .tenthSecond
            }
            try mouseClick(at: target.point, options: options, target: target.pointer)
            if native { AXMenuSessions.closeSynthetic(bundle) }
            return .tenthSecond
        }
        if let location = try point(from: asDict(a["at"]) ?? [:], bundle: bundle) {
            cursor(for: bundle) {
                CursorOverlay.shared.place(at: location.point, targetWindowID: location.pointer.windowID)
                CursorOverlay.shared.press()
            }
            try mouseClick(at: location.point, options: options, target: location.pointer)
            return .applicationDefault
        } else {
            throw ServiceError(.unhandledEvent, "click requires an element index or coordinate")
        }
    }

    private static func nativeElementClick(_ a: JSON, bundle: String, options: ClickOptions) throws -> AXSettler.Polling {
        let at = asDict(a["at"]) ?? [:]
        let initial = try secondaryTarget(at, bundle: bundle, native: true)
        let target = try SecondaryCursorPreparation.prepare(initial,
            position: { try AXClickableTarget.secondaryPosition($0.element, bundle: bundle) },
            cursorEnabled: { CursorCapture.enabled },
            move: { try moveCursor(to: $1, bundle: bundle, windowID: $0.windowID) },
            refetch: { try secondaryTarget(at, bundle: bundle, native: true) },
            validate: { try NativeInteractionTargetPolicy.requireAllowed(element: $0.element) },
            checkpoint: RequestRuntime.check,
            prepareFocus: { _ = try SyntheticFocusSessions.prepare(app: AppResolver.require(bundle)) })
        // Read the cursor flag again after prepareToInteract; cursor
        // creation and menu handling precede the force-mouse preference.
        let cursorEnabled = CursorCapture.enabled
        var cursorVisible = false
        if cursorEnabled {
            cursor(for: bundle, enabled: true) { cursorVisible = CursorOverlay.shared.prepareInteraction() }
        }
        let element = target.element
        if options.canUseNativeAXPress, try AXMenuSessions.select(element, bundle: bundle) { return .applicationDefault }
        let forceMouse = ComputerUseFeaturePreferences.alwaysSimulateClick
        let actions = try AX.onElement(element) { AX.actionNames(element) }
        let action = [kAXPickAction as String, kAXPressAction as String].first(where: actions.contains)
        if options.canUseNativeAXPress, let action, !forceMouse,
           !(try webClickRequiresMouse(element, at: AXClickableTarget.nativePoint(element, bundle: bundle), bundle: bundle)) {
            if cursorVisible { try pressSecondaryCursor(bundle: bundle, enabled: true) }
            _ = try AXNativeClickFocus.prepare(element, bundle: bundle, delivery: .accessibility,
                heldKey: options.chord != nil, webShaped: { try webClickShape(element, bundle: bundle) })
            try AXNativeElementActions.perform(element, action: action)
            AXMenuSessions.closeSynthetic(bundle)
            return .tenthSecond
        }
        guard let point = try AXClickableTarget.nativePoint(element, bundle: bundle) else {
            throw ServiceError(.unknownError, "cannotClickOffscreenElement")
        }
        // Resolve native event routing only when mouse delivery is required.
        // AX actions do not require a valid pointer destination or display.
        let pointer = try AXPointerTarget.forElement(element, hostPID: AppResolver.pid(for: bundle))
        let flags = try AXNativeClickFocus.prepare(element, bundle: bundle, delivery: .mouse,
            heldKey: options.chord != nil, webShaped: { try webClickShape(element, bundle: bundle) })
        try nativeMouseClick(at: point, options: options, target: pointer, bundle: bundle,
                             cursorVisible: cursorVisible, additionalFlags: flags)
        AXMenuSessions.closeSynthetic(bundle)
        return .tenthSecond
    }

    private static func validateAXActionStatus(_ status: AXError, native: Bool, message: String) throws {
        guard status != .success else { return }
        if native, status == .cannotComplete || status == .attributeUnsupported { return }
        throw ServiceError(.accessibilityError, "\(message) (\(status.rawValue))")
    }

    private static func webClickShape(_ element: AXUIElement, bundle: String) throws -> Bool {
        // Walk self/parents (counter 0...300), then test the
        // com.apple.Safari bundle prefix.
        func ancestorsContain(_ start: AXUIElement, matches: (AXUIElement) -> Bool) throws -> Bool {
            for node in AXParentChain(start: start, parent: { AX.axElement(AX.copy($0, kAXParentAttribute as String)) }) {
                try RequestRuntime.check()
                if matches(node) { return true }
            }
            return false
        }
        let web = try ancestorsContain(element) { AX.string($0, kAXRoleAttribute as String) == "AXWebArea" }
        return web || bundle.hasPrefix("com.apple.Safari")
    }

    private static func webClickRequiresMouse(_ element: AXUIElement, at point: @autoclosure () throws -> CGPoint?, bundle: String) throws -> Bool {
        guard try webClickShape(element, bundle: bundle) else { return false }
        // A failed clickable-point query is swallowed before hit testing.
        guard let point = try? point() else { return false }
        // Failed/absent app-local hit tests count as false.
        var hit: AXUIElement?
        let app = AXUIElementCreateApplication(try AppResolver.require(bundle).running.processIdentifier)
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let hit else { return false }
        for node in AXParentChain(start: hit, parent: { AX.axElement(AX.copy($0, kAXParentAttribute as String)) }) {
            try RequestRuntime.check()
            if CFEqual(node, element) { return true }
        }
        return false
    }

    private static func nativeCoordinateClick(_ a: JSON, bundle: String, options: ClickOptions) throws -> AXSettler.Polling {
        let at = asDict(a["at"]) ?? [:]
        guard let coordinate = asDict(at["coordinate"]), let pair = array(coordinate["_0"]), pair.count == 2,
              let x = doubleValue(pair[0]), let y = doubleValue(pair[1]) else {
            throw ServiceError(.unhandledEvent, "click requires an element index or coordinate")
        }
        let mapped = try nativeCoordinatePoint(CGPoint(x: x, y: y), bundle: bundle)
        try recordNativeCursor(CGPoint(x: x, y: y), bundle: bundle)
        return try nativeCoordinateAction(at: mapped.point, hostPID: mapped.hostPID, bundle: bundle, options: options)
    }

    private static func nativeCoordinateAction(at point: CGPoint, hostPID: Int32, bundle: String,
                                               options: ClickOptions, dragTo: CGPoint? = nil) throws -> AXSettler.Polling {
        let resolved = try AXPointerTarget.resolveContext(at: point, hostPID: hostPID)
        let target = resolved.pointer
        // Coordinate preparation checks the
        // receiving PID, creates/moves the cursor regardless of its flag,
        // awaits arrival, then posts one unmodified physical movement.
        try NativeInteractionTargetPolicy.requireAllowed(processIdentifier: target.eventPID)
        try moveCursor(to: point, bundle: bundle, windowID: resolved.cursorWindowID,
                       timing: dragTo == nil ? .closeEnough : .finished)
        let isMenu = resolved.menu != nil
        if NativeMenuClick.requiresMouseMovement(isMenu: isMenu) {
            try nativePointerMovement(at: point, target: target)
        }
        if try NativeMenuClick.perform(isMenu: isMenu, hasHoldDuration: options.hasExplicitDuration,
            hasHeldKey: options.chord != nil, hit: resolved.element,
            actions: { node in try AX.onElement(node) { AX.actionNames(node) } },
            press: { try AXNativeElementActions.perform($0, action: kAXPressAction as String) }) {
            return .applicationDefault
        }
        let webShaped = try resolved.element.map { try webClickShape($0, bundle: bundle) } ?? false
        var visible = false
        cursor(for: bundle, enabled: true) { visible = CursorOverlay.shared.prepareInteraction() }
        let enabled = CursorCapture.enabled
        let flags = try AXNativeClickFocus.prepare(resolved.element, bundle: bundle, delivery: .mouse,
            heldKey: options.chord != nil, webShaped: { webShaped })
        try nativeMouseClick(at: point, options: options, target: target, bundle: bundle,
            cursorVisible: visible && enabled, additionalFlags: flags, dragTo: dragTo)
        AXMenuSessions.closeSynthetic(bundle)
        return .applicationDefault
    }

    private static func nativePointerMovement(at point: CGPoint, target: PointerTarget) throws {
        try RequestRuntime.check()
        let number = SynthesizedEventNumbers.shared.next()
        let event = try MouseClickEventFactory.movement(at: point, windowID: target.windowID, eventNumber: number)
        try postPointerEvent(event, target: target, preserveMouseIdentity: true, native: true)
        // SynthesizedEvent.send(to:delay:) waits after every event, including
        // this one-event batch, before entering sendClick.
        try RequestRuntime.wait(0.01)
    }

    /// The sender routes pointer events to the app/window, rather than
    /// relying on whichever window happens to be frontmost when HID handles it.
    private static func postPointerEvent(_ unrouted: CGEvent?, target: PointerTarget?,
                                         preserveMouseIdentity: Bool = false, native: Bool = false) throws {
        try RequestRuntime.check()
        if let target { try AXPointerTarget.requireCurrent(target) }
        try postPointerEventUnchecked(unrouted, target: target, preserveMouseIdentity: preserveMouseIdentity, native: native)
    }

    private static func postPointerEventUnchecked(_ unrouted: CGEvent?, target: PointerTarget?,
                                                  preserveMouseIdentity: Bool = false, native: Bool = false) throws {
        guard let unrouted else { throw ServiceError(.unhandledEvent, "Could not create pointer event") }
        var event = unrouted
        if let target {
            if !(native && event.type == .scrollWheel), let type = NSEvent.EventType(rawValue: UInt(event.type.rawValue)) {
                let point = event.location
                let local = CGPoint(x: point.x - target.screenFrame.minX,
                                    y: target.screenFrame.height - (point.y - target.screenFrame.minY))
                // NSEvent supplies the window association also needed by wheel
                // events. Keep wheel data while changing the routed event type.
                let number = preserveMouseIdentity ? unrouted.getIntegerValueField(.mouseEventNumber) : Int64(event.timestamp & 0x7fffffff)
                // Native event factories create with the global point and
                // timestamp 0, then set global/window
                // locations separately. The sender refreshes time at posting.
                guard let routed = NSEvent.mouseEvent(with: type == .scrollWheel ? .mouseMoved : type, location: native ? point : local, modifierFlags: [],
                    timestamp: native ? 0 : ProcessInfo.processInfo.systemUptime, windowNumber: Int(target.windowID),
                    context: nil, eventNumber: Int(number),
                    clickCount: Int(event.getIntegerValueField(.mouseEventClickState)), pressure: 1)?.cgEvent else {
                    throw ServiceError(.unhandledEvent, "Could not create window-relative mouse event")
                }
                routed.location = point
                routed.flags = unrouted.flags
                routed.type = unrouted.type
                if unrouted.type == .scrollWheel {
                    let fields: [CGEventField] = [
                        .scrollWheelEventDeltaAxis1, .scrollWheelEventDeltaAxis2, .scrollWheelEventDeltaAxis3,
                        .scrollWheelEventFixedPtDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis3,
                        .scrollWheelEventPointDeltaAxis1, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventPointDeltaAxis3,
                        .scrollWheelEventIsContinuous, .scrollWheelEventScrollPhase, .scrollWheelEventMomentumPhase,
                    ]
                    for field in fields { routed.setIntegerValueField(field, value: unrouted.getIntegerValueField(field)) }
                }
                routed.setIntegerValueField(.mouseEventButtonNumber, value: unrouted.getIntegerValueField(.mouseEventButtonNumber))
                if preserveMouseIdentity {
                    routed.setIntegerValueField(.mouseEventSubtype, value: unrouted.getIntegerValueField(.mouseEventSubtype))
                }
                event = routed
            }
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(target.windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(target.windowID))
            guard let setWindowLocation else {
                throw ServiceError(.unhandledEvent, "Window-relative mouse event API is unavailable on this macOS version")
            }
            setWindowLocation(event, CGPoint(x: event.location.x - target.screenFrame.minX,
                                             y: event.location.y - target.screenFrame.minY))
            if native { event.timestamp = DispatchTime.now().uptimeNanoseconds }
            UserInteraction.markSynthesized(event)
            event.postToPid(target.eventPID)
        } else {
            UserInteraction.markSynthesized(event)
            event.post(tap: .cghidEventTap)
        }
    }

    private static func nativeMouseClick(at point: CGPoint, options: ClickOptions, target: PointerTarget,
                                         bundle: String, cursorVisible: Bool, additionalFlags: CGEventFlags = [],
                                         dragTo: CGPoint? = nil) throws {
        // Prepare every pair before pressing keys or delivering any mouse
        // event, as one batch.
        var pairs: [NativeMouseClick.Gesture<CGEvent>] = []
        for index in 1...options.count {
            try RequestRuntime.check()
            let number = SynthesizedEventNumbers.shared.next()
            let flags = (options.chord?.flags ?? []).union(additionalFlags)
            if let dragTo {
                let events = try MouseClickEventFactory.dragEvents(from: point, to: dragTo, button: UInt32(options.button),
                    clickCount: Int64(index), flags: flags, windowID: target.windowID, eventNumber: number,
                    nextMotionEventNumber: { SynthesizedEventNumbers.shared.next() })
                pairs.append(.init(down: events.down, motion: events.motion, up: events.up))
            } else {
                let events = try MouseClickEventFactory.events(at: point, button: UInt32(options.button),
                    clickCount: Int64(index), flags: flags, windowID: target.windowID, eventNumber: number)
                pairs.append(.init(down: events.down, motion: [], up: events.up))
            }
        }
        let update: ((Bool) -> Void)? = cursorVisible ? { pressed in
            cursor(for: bundle, enabled: true) { CursorOverlay.shared.setPressed(pressed) }
        } : nil
        try withHeldKeys(options.chord, pid: target.eventPID) { _ in
            try NativeMouseClick.deliverGestures(pairs, hold: options.hasExplicitDuration ? .seconds(options.duration) : nil,
                interval: dragTo == nil ? NativeMouseClick.interval : nil,
                cursor: update,
                post: { try postPointerEvent($0, target: target, preserveMouseIdentity: true, native: true) },
                wait: { try RequestRuntime.wait(NativeMouseClick.seconds($0)) }, checkpoint: RequestRuntime.check,
                recoverUp: { try? postPointerEventUnchecked($0, target: target, preserveMouseIdentity: true, native: true) })
        }
    }

    private static func mouseClick(at p: CGPoint, options: ClickOptions, target: PointerTarget) throws {
        let source = CGEventSource(stateID: .hidSystemState)
        try withHeldKeys(options.chord, pid: target.eventPID) { flags in
        for i in 1...options.count {
            try RequestRuntime.check()
            let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
            move?.flags = flags
            try postPointerEvent(move, target: target)
            let number = SynthesizedEventNumbers.shared.next()
            let events = try MouseClickEventFactory.events(at: p, button: UInt32(options.button), clickCount: Int64(i),
                flags: flags, windowID: target.windowID, eventNumber: number)
            try postPointerEvent(events.down, target: target, preserveMouseIdentity: true)
            do {
                try RequestRuntime.wait(options.duration)
                try postPointerEvent(events.up, target: target, preserveMouseIdentity: true)
            } catch {
                try? postPointerEventUnchecked(events.up, target: target, preserveMouseIdentity: true)
                throw error
            }
            if i < options.count { try RequestRuntime.wait(0.02) }
        }
        }
    }

    private static func nativeDrag(_ a: JSON, bundle: String) throws {
        guard let from = array(a["from"]), from.count == 2, let to = array(a["to"]), to.count == 2,
              let fx = doubleValue(from[0]), let fy = doubleValue(from[1]),
              let tx = doubleValue(to[0]), let ty = doubleValue(to[1]) else {
            throw ServiceError(.unhandledEvent, "drag requires from/to coordinates")
        }
        // The dispatcher maps the destination before shared click maps start.
        let end = try nativeCoordinatePoint(CGPoint(x: tx, y: ty), bundle: bundle)
        let start = try nativeCoordinatePoint(CGPoint(x: fx, y: fy), bundle: bundle)
        try recordNativeCursor(CGPoint(x: fx, y: fy), bundle: bundle)
        _ = try nativeCoordinateAction(at: start.point, hostPID: start.hostPID, bundle: bundle,
            options: ClickOptions([:]), dragTo: end.point)
    }

    private static func drag(_ a: JSON, bundle: String, native: Bool) throws {
        if native { try nativeDrag(a, bundle: bundle); return }
        guard let from = array(a["from"]), from.count == 2, let to = array(a["to"]), to.count == 2,
              let fx = doubleValue(from[0]), let fy = doubleValue(from[1]),
              let tx = doubleValue(to[0]), let ty = doubleValue(to[1]) else {
            throw ServiceError(.unhandledEvent, "drag requires from/to coordinates")
        }
        activate(bundle)
        let state = try coordinateSnapshot(bundle)
        let geometry = state.geometry!
        // Both endpoints refer to the same screenshot.
        let start = try geometry.screenPoint(from: CGPoint(x: fx, y: fy))
        let end = try geometry.screenPoint(from: CGPoint(x: tx, y: ty))
        let target = try AXPointerTarget.resolve(at: start, hostPID: geometry.ownerPID)
        let number = SynthesizedEventNumbers.shared.next()
        let events = try dragEvents(from: start, to: end, windowID: target.windowID, eventNumber: number)
        cursor(for: bundle) {
            CursorOverlay.shared.drag(from: start, to: end, duration: 0.192, targetWindowID: target.windowID)
        }
        try postPointerEvent(events.down, target: target, preserveMouseIdentity: true)
        do {
            // Give controls a run-loop turn to consume motion before AppKit
            // coalesces the intermediate position into the endpoint.
            for event in events.motion {
                try RequestRuntime.wait(0.016)
                try postPointerEvent(event, target: target, preserveMouseIdentity: true)
            }
            try RequestRuntime.wait(0.016)
            try postPointerEvent(events.up, target: target, preserveMouseIdentity: true)
        } catch {
            try? postPointerEventUnchecked(events.up, target: target, preserveMouseIdentity: true)
            throw error
        }
    }

    // Drags use one event number for the press/release and a
    // second number for the three motion samples of the same gesture.
    private static func dragEvents(from start: CGPoint, to end: CGPoint, windowID: UInt32,
                                   eventNumber: Int64) throws -> (down: CGEvent, motion: [CGEvent], up: CGEvent) {
        let source = CGEventSource(stateID: .hidSystemState)
        func event(_ type: CGEventType, at point: CGPoint, number: Int64) throws -> CGEvent {
            guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
                throw ServiceError(.unhandledEvent, "Could not create drag event")
            }
            let motion = type == .leftMouseDragged
            event.flags = []
            event.setIntegerValueField(.mouseEventClickState, value: motion ? 0 : 1)
            event.setIntegerValueField(.mouseEventNumber, value: number)
            event.setIntegerValueField(.mouseEventSubtype, value: 3)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(windowID))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(windowID))
            return event
        }
        let midpoint = CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
        return try SynthesizedMouseGesture.drag(pressNumber: eventNumber,
            nextMotionNumber: { SynthesizedEventNumbers.shared.next() },
            press: { try event(.leftMouseDown, at: start, number: $0) },
            motion: { number in try [start, midpoint, end].map { try event(.leftMouseDragged, at: $0, number: number) } },
            release: { try event(.leftMouseUp, at: end, number: $0) })
    }

    private static func recordNativeCursor(_ point: CGPoint, bundle: String) throws {
        let app = try AppResolver.require(bundle)
        try AXIndex.shared.updateNativeCursor(NativeCoordinateConversion.truncate(point), for: bundle,
                                              processKey: AXCapture.processKey(app))
    }

    private static func nativePointerState(_ bundle: String) throws -> (layout: ScreenshotGeometry.NativeLayout, position: CGPoint, hostPID: Int32) {
        let app = try AppResolver.require(bundle)
        guard let state = AXIndex.shared.nativePointerState(for: bundle, processKey: AXCapture.processKey(app)) else {
            throw ServiceError(.noActiveSession, "Read get_app_state before using coordinates")
        }
        return (state.layout, state.position, app.running.processIdentifier)
    }

    private static func nativeMoveMouse(to point: CGPoint, bundle: String) throws {
        // Store screenshot coordinates before resolving a target.
        try recordNativeCursor(point, bundle: bundle)
        let state = try nativePointerState(bundle)
        let global = state.layout.screenPoint(from: state.position)
        let resolved = try AXPointerTarget.resolveContext(at: global, hostPID: state.hostPID)
        try NativeInteractionTargetPolicy.requireAllowed(processIdentifier: resolved.pointer.eventPID)
        try moveCursor(to: global, bundle: bundle, windowID: resolved.cursorWindowID)
        if resolved.menu == nil {
            let current = try nativePointerState(bundle)
            try nativePointerMovement(at: current.layout.screenPoint(from: current.position), target: resolved.pointer)
        }
    }

    private static func nativeScroll(_ a: JSON, bundle: String) throws {
        guard let rawDirection = str(a["direction"]), let direction = NativeScroll.Direction(rawDirection) else {
            throw ServiceError(.unhandledEvent, "Missing scroll direction")
        }
        let pages: Double
        if let raw = a["pages"] {
            guard let value = doubleValue(raw) else { throw ServiceError(.unhandledEvent, "Invalid scroll pages") }
            pages = value
        } else { pages = 1 }
        try NativeScroll.validate(pages: pages)
        let at = asDict(a["at"]) ?? [:]
        let size: CGSize
        if let coordinate = asDict(at["coordinate"]), let pair = array(coordinate["_0"]), pair.count == 2,
           let x = doubleValue(pair[0]), let y = doubleValue(pair[1]) {
            try nativeMoveMouse(to: CGPoint(x: x, y: y), bundle: bundle)
            size = try nativePointerState(bundle).layout.visibleSize
        } else {
            guard let index = elementIndex(from: at), let numericID = Int(index) else {
                throw ServiceError(.unknownError, "invalidElementID")
            }
            let normalized: JSON = ["elementID": ["_0": String(numericID)]]
            let initial = try secondaryTarget(normalized, bundle: bundle, native: true)
            let target = try SecondaryCursorPreparation.prepare(initial,
                position: { try AXClickableTarget.secondaryPosition($0.element, bundle: bundle) },
                cursorEnabled: { CursorCapture.enabled },
                move: { try moveCursor(to: $1, bundle: bundle, windowID: $0.windowID) },
                refetch: { try secondaryTarget(normalized, bundle: bundle, native: true) },
                validate: { try NativeInteractionTargetPolicy.requireAllowed(element: $0.element) },
                checkpoint: RequestRuntime.check,
                prepareFocus: { _ = try SyntheticFocusSessions.prepare(app: AppResolver.require(bundle)) })
            // Capture the extent before the second clickablePoint
            // lookup. A missing point keeps the controller's preceding cursor.
            let frame: CGRect? = try AX.onElement(target.element) {
                if let frame = AX.rectangle(target.element, "AXFrame") { return frame }
                guard let origin = AX.point(target.element, kAXPositionAttribute as String),
                      let size = AX.size(target.element, kAXSizeAttribute as String) else { return nil }
                return CGRect(origin: origin, size: size)
            }
            if let frame { size = frame.size }
            else { size = try nativePointerState(bundle).layout.visibleSize }
            if let point = try AXClickableTarget.nativePoint(target.element, bundle: bundle) {
                let layout = try nativePointerState(bundle).layout
                let scale = layout.pointScale > 0 ? layout.pointScale : 1
                let scaled = CGPoint(x: (point.x - layout.windowOrigin.x) / scale,
                                     y: (point.y - layout.windowOrigin.y) / scale)
                try nativeMoveMouse(to: scaled, bundle: bundle)
            }
        }
        let delta = try NativeScroll.delta(direction: direction, pages: pages, size: size)
        try nativeSendScroll(deltaX: delta.x, deltaY: delta.y, bundle: bundle)
    }

    private static func nativeSendScroll(deltaX: Int64, deltaY: Int64, bundle: String) throws {
        let state = try nativePointerState(bundle)
        let resolved = try AXPointerTarget.resolveContext(at: state.layout.screenPoint(from: state.position), hostPID: state.hostPID)
        try NativeInteractionTargetPolicy.requireAllowed(processIdentifier: resolved.pointer.eventPID)
        let current = try nativePointerState(bundle)
        let event = try ScrollEventFactory.event(at: current.layout.screenPoint(from: current.position),
            deltaX: deltaX, deltaY: deltaY, windowID: resolved.pointer.windowID)
        try postPointerEvent(event, target: resolved.pointer, native: true)
        // SynthesizedEvent.send(to:delay:) includes the last event's delay.
        try RequestRuntime.wait(0.01)
    }

    private static func scroll(_ a: JSON, bundle: String, native: Bool) throws {
        if native { try nativeScroll(a, bundle: bundle); return }
        guard let dir = str(a["direction"]) else { throw ServiceError(.unhandledEvent, "Missing scroll direction") }
        let pages: Double
        if let raw = a["pages"] {
            guard let number = doubleValue(raw) else { throw ServiceError(.unhandledEvent, "Invalid scroll pages") }
            pages = number
        } else { pages = 1 }
        guard pages.isFinite, pages > 0, pages <= Double(Int32.max) / 10 else {
            throw ServiceError(.unhandledEvent, "pages must be finite, positive and within the scroll event range")
        }
        let amount = Int32(max(1, pages * 10))
        var vertical: Int32 = 0
        var horizontal: Int32 = 0
        switch dir {
        case "up": vertical = amount
        case "down": vertical = -amount
        case "left": horizontal = amount
        case "right": horizontal = -amount
        default: throw ServiceError(.unhandledEvent, "Missing scroll direction")
        }
        let target = asDict(a["at"]) ?? [:]
        let location: CGPoint
        let pointerTarget: PointerTarget
        if let element = try element(from: target, bundle: bundle) {
            let revealed = try AXClickableTarget.prepare(element, bundle: bundle) {
                guard let refreshed = try self.element(from: target, bundle: bundle) else {
                    throw ServiceError(.accessibilityError, "Scroll target disappeared after revealing it")
                }
                return refreshed
            }
            location = revealed.point
            pointerTarget = revealed.pointer
        } else if let coordinate = try point(from: target, bundle: bundle) {
            location = coordinate.point
            pointerTarget = coordinate.pointer
        } else {
            throw ServiceError(.accessibilityError, "scroll requires a valid element index or coordinate")
        }
        activate(bundle)
        let source = CGEventSource(stateID: .hidSystemState)
        cursor(for: bundle) { CursorOverlay.shared.place(at: location, targetWindowID: pointerTarget.windowID) }
        try postPointerEvent(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: location, mouseButton: .left), target: pointerTarget)
        let scroll = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0)
        scroll?.location = location
        try postPointerEvent(scroll, target: pointerTarget)
    }

    private static func paste(_ a: JSON, bundle: String, native: Bool) throws {
        guard let text = str(a["text"]) else { throw ServiceError(.unhandledEvent, "paste requires text") }
        let format = str(a["format"]) ?? "text"
        guard ["text", "md", "html"].contains(format) else {
            throw ServiceError(.unhandledEvent, "Unknown paste format")
        }
        while !clipboardLock.lock(before: Date(timeIntervalSinceNow: 0.01)) { try RequestRuntime.check() }
        defer { clipboardLock.unlock() }
        try RequestRuntime.check()
        _ = try keyboardPID(bundle)
        let representations = try NativePaste.representations(text: text, format: format)
        try NativePaste.perform(representations, send: {
            try pressKey(["key": "Super_L+v"], bundle: bundle)
        }, settle: {
            let app = try AppResolver.require(bundle)
            try AXSettler.wait(app: AXUIElementCreateApplication(app.running.processIdentifier), pid: app.running.processIdentifier,
                               deduplicateTitles: native)
        })
    }

    private static func setValue(_ a: JSON, bundle: String) throws {
        guard let el = try element(from: a, bundle: bundle, ignoreValueChange: true) else {
            throw ServiceError(.accessibilityError, "setValue requires a valid element index")
        }
        let value = str(a["value"]) ?? ""
        let err = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFString)
        if err != .success { throw ServiceError(.accessibilityError, "Failed to set element value (\(err.rawValue))") }
    }

    private static func moveCursor(to point: CGPoint, bundle: String, windowID: UInt32?, timing: CursorInteractionTiming = .finished) throws {
        guard point.x.isFinite, point.y.isFinite else {
            throw ServiceError(.accessibilityError, "Cursor target has invalid geometry")
        }
        guard !Thread.isMainThread else {
            throw ServiceError(.unknownError, "Cursor movement requires a connection worker")
        }
        let pending = PendingResult<Bool>(discard: { _ in })
        do {
            cursor(for: bundle, enabled: true) {
                CursorOverlay.shared.place(at: point, targetWindowID: windowID,
                    nextInteractionTiming: timing,
                    completion: { pending.complete(.success($0)) })
            }
            try RequestRuntime.wait(for: pending.signal, maximumSeconds: 120)
            _ = try pending.take()
        } catch {
            pending.abandon()
            throw error
        }
    }

    private static func selectText(_ a: JSON, bundle: String, native: Bool) throws {
        guard let index = elementIndex(from: a), let text = str(a["text"]) else {
            throw ServiceError(.accessibilityError, "selectText requires a valid element index and text")
        }
        let el: AXUIElement
        let range: NSRange
        let window: EventStreamNativeWindow?
        if let resolved = try AXIndex.shared.nativeSelection(index, for: bundle, text: text,
            prefix: str(a["prefix"]), suffix: str(a["suffix"]), selection: str(a["selection"]) ?? "text") {
            el = resolved.element; range = resolved.range; window = resolved.window
        } else {
            guard let element = try element(from: a, bundle: bundle, ignoreValueChange: true) else {
                throw ServiceError(.accessibilityError, "The element does not expose selectable text")
            }
            try AX.requireTextSelectionSettable(element)
            guard let current = AX.string(element, kAXValueAttribute as String) else {
                throw ServiceError(.accessibilityError, "The element does not expose selectable text")
            }
            el = element
            window = nil
            range = try TextSelection.range(in: current, text: text, prefix: str(a["prefix"]),
                suffix: str(a["suffix"]), selection: str(a["selection"]) ?? "text")
        }
        if native, let window {
            try SelectionCursorPositioning.prepare(enabled: CursorCapture.enabled, window: window.frame,
                checkpoint: RequestRuntime.check, bounds: { AX.boundsForRange(el, range: range) },
                scroll: { try AXClickableTarget.scrollToVisible(el, frame: $0) },
                position: { try moveCursor(to: $0, bundle: bundle, windowID: window.id) })
        }
        _ = try keyboardPID(bundle, element: el)
        var axRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &axRange) else {
            throw ServiceError(.accessibilityError, "Could not construct the text range")
        }
        let result = try AX.onElement(el) { AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, value) }
        guard result == .success else {
            throw ServiceError(.accessibilityError, "Failed to set text selection (\(result.rawValue))")
        }
    }

    private struct SecondaryTarget {
        let index: String
        let element: AXUIElement
        let actions: [EventStreamNodeAction]?
        let windowID: UInt32?
    }

    private static func secondaryTarget(_ a: JSON, bundle: String, native: Bool) throws -> SecondaryTarget {
        guard let index = elementIndex(from: a) else {
            throw ServiceError(.accessibilityError, "performSecondaryAction requires a valid element index")
        }
        if native, let resolved = try AXIndex.shared.nativeSecondary(index, for: bundle) {
            return SecondaryTarget(index: index, element: resolved.element, actions: resolved.actions, windowID: resolved.windowID)
        }
        guard let fallback = try element(from: a, bundle: bundle) else {
            throw ServiceError(.accessibilityError, "performSecondaryAction requires a valid element index")
        }
        return SecondaryTarget(index: index, element: fallback, actions: nil, windowID: nil)
    }

    private static func pressSecondaryCursor(bundle: String, enabled: Bool? = nil) throws {
        guard enabled ?? CursorCapture.enabled else { return }
        var shown = false
        cursor(for: bundle, enabled: true) {
            shown = CursorOverlay.shared.press(animationDuration: SecondaryCursorPreparation.pressAnimationSeconds)
        }
        if shown {
            guard !Thread.isMainThread else {
                throw ServiceError(.unknownError, "Cursor press waiting requires a connection worker")
            }
            try RequestRuntime.wait(SecondaryCursorPreparation.pressAnimationSeconds)
            try RequestRuntime.wait(SecondaryCursorPreparation.pressHoldSeconds)
        }
    }

    private static func secondary(_ a: JSON, bundle: String, native: Bool) throws {
        var target = try secondaryTarget(a, bundle: bundle, native: native)
        if native {
            target = try SecondaryCursorPreparation.prepare(target,
                position: { try AXClickableTarget.secondaryPosition($0.element, bundle: bundle) },
                cursorEnabled: { CursorCapture.enabled },
                move: { try moveCursor(to: $1, bundle: bundle, windowID: $0.windowID) },
                refetch: { try secondaryTarget(a, bundle: bundle, native: true) },
                validate: { try NativeInteractionTargetPolicy.requireAllowed(element: $0.element) },
                checkpoint: RequestRuntime.check,
                prepareFocus: { _ = try SyntheticFocusSessions.prepare(app: AppResolver.require(bundle)) })
        }
        let el = target.element
        guard let requested = str(a["action"]) else { throw ServiceError(.unhandledEvent, "Missing secondary action name") }
        let action: String
        if native {
            // Compare the requested text with each published description,
            // then execute its name. Preserve first-match and
            // Swift's canonical String equality; raw AX names are not aliases.
            let descriptions = try target.actions ?? AX.secondaryActionDescriptions(el)
            guard let selected = descriptions.first(where: { $0.description == requested }) else {
                // Controller.Error case 3 falls through to the generic error
                // mapper, whose wire code is unknownError.
                throw ServiceError(.unknownError, "\(requested) is not a valid secondary action for \(target.index)")
            }
            action = selected.name
        } else { action = requested }
        if native, action == kAXPickAction as String, try AXMenuSessions.select(el, bundle: bundle) { return }
        let isBarItem: Bool
        if native {
            isBarItem = try AX.onElement(el) { AX.string(el, kAXRoleAttribute as String) == kAXMenuBarItemRole as String }
        } else { isBarItem = false }
        if isBarItem, action == kAXCancelAction as String {
            AXMenuSessions.close(bundle)
            return
        }
        if native {
            try pressSecondaryCursor(bundle: bundle)
            try AXNativeElementActions.perform(el, action: action)
        } else {
            let err = AXUIElementPerformAction(el, action as CFString)
            try validateAXActionStatus(err, native: false, message: "Failed to perform \(action)")
        }
        if isBarItem, action == kAXPressAction as String || action == kAXPickAction as String {
            AXMenuSessions.activate(el, bundle: bundle)
        } else if native {
            AXMenuSessions.closeSynthetic(bundle)
        }
    }

    private static func typeText(_ text: String, bundle: String) throws {
        if text.isEmpty { return }
        let pid = try keyboardPID(bundle)
        if let location = focusedElementLocation(bundle) {
            cursor(for: bundle) { CursorOverlay.shared.place(at: location.point, targetWindowID: location.windowID) }
        }
        for scalar in text.unicodeScalars {
            try RequestRuntime.check()
            let utf16 = Array(String(scalar).utf16)
            try keyboardEvent(code: 0, down: true, flags: [], pid: pid, unicode: utf16)
            try keyboardEvent(code: 0, down: false, flags: [], pid: pid, unicode: utf16)
        }
    }

    private static func pressKey(_ a: JSON, bundle: String) throws {
        guard let input = str(a["key"]) ?? str(a["_0"]) else {
            throw ServiceError(.unhandledEvent, "pressKey requires a key")
        }
        let chord = try KeyChord.parse(input)
        let duration = try KeyChord.duration(a["duration"])
        if let literal = chord.literal {
            guard duration == 0 else { throw ServiceError(.unhandledEvent, "Cannot hold a Unicode-only key") }
            try typeText(literal, bundle: bundle)
            return
        }
        let pid = try keyboardPID(bundle)
        if let location = focusedElementLocation(bundle) {
            cursor(for: bundle) { CursorOverlay.shared.place(at: location.point, targetWindowID: location.windowID) }
        }
        try withHeldKeys(chord, pid: pid) { _ in try RequestRuntime.wait(duration) }
    }
}
