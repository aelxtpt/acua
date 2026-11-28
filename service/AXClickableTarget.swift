import AppKit
import ApplicationServices

enum AXClickableTarget {
    struct Target { let element: AXUIElement; let point: CGPoint; let pointer: PointerTarget }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = AX.point(element, kAXPositionAttribute as String), let size = AX.size(element, kAXSizeAttribute as String) else { return nil }
        let frame = CGRect(origin: position, size: size)
        return ClickableGeometry.valid(frame) ? frame : nil
    }
    private static func displays() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
    private static func ancestors(_ element: AXUIElement) throws -> [AXUIElement] {
        var result: [AXUIElement] = [], seen = Set<AXReference>(), current: AXUIElement? = element
        while let node = current {
            try RequestRuntime.check()
            // 0x1007AAB24 walks to an application or clipping boundary; its
            // visible-frame loop has no numeric depth cap. Keep cancellation
            // and a malformed-cycle error without rejecting valid deep trees.
            guard seen.insert(AXReference(element: node)).inserted else {
                throw ServiceError(.accessibilityError, "Cyclic accessibility ancestry")
            }
            guard let role = AX.string(node, kAXRoleAttribute as String) else {
                throw ServiceError(.accessibilityError, "Control disappeared while checking visibility")
            }
            if role == kAXApplicationRole as String { break }
            result.append(node)
            if ClickableGeometry.boundary(role: role) { break }
            current = AX.axElement(AX.copy(node, kAXParentAttribute as String))
        }
        return result
    }
    private static func chessPoint(_ element: AXUIElement, application: AXUIElement) throws -> CGPoint? {
        guard AX.string(element, kAXRoleAttribute as String) == kAXButtonRole as String,
              ClickableGeometry.isChessSquareTitle(AX.string(element, kAXTitleAttribute as String)),
              let bounds = AX.rectangle(element, "AXFrame") ?? frame(element) else { return nil }
        return try ClickableGeometry.chessSquarePoint(frame: bounds, parentFrame: {
            guard let parent = AX.axElement(AX.copy(element, kAXParentAttribute as String)) else { return nil }
            return AX.rectangle(parent, "AXFrame") ?? frame(parent)
        }, matches: { point in
            try RequestRuntime.check()
            guard point.x.isFinite, point.y.isFinite,
                  abs(point.x) <= CGFloat(Float.greatestFiniteMagnitude),
                  abs(point.y) <= CGFloat(Float.greatestFiniteMagnitude) else { return nil }
            var hit: AXUIElement?
            guard AXUIElementCopyElementAtPosition(application, Float(point.x), Float(point.y), &hit) == .success,
                  let hit else { return nil }
            return CFEqual(hit, element)
        })
    }

    private static func point(_ element: AXUIElement, chessApplication: AXUIElement?, requireDisplay: Bool = true,
                              frameOverride: CGRect? = nil) throws -> CGPoint? {
        if let chessApplication, let chess = try chessPoint(element, application: chessApplication) { return chess }
        guard let frame = frameOverride ?? frame(element) else { return nil }
        var clips: [CGRect] = []
        for ancestor in try ancestors(element) {
            let role = AX.string(ancestor, kAXRoleAttribute as String) ?? ""
            if ClickableGeometry.clips(role: role, actions: AX.actionNames(ancestor)) {
                let supplied = frameOverride != nil && CFEqual(ancestor, element) ? frame : nil
                guard let clippingFrame = supplied ?? self.frame(ancestor) else { return nil }
                clips.append(clippingFrame)
            }
        }
        return ClickableGeometry.point(frame: frame, clips: clips, displays: requireDisplay ? displays() : nil)
    }
    private static func scrollArea(_ area: AXUIElement, target: CGRect) throws -> Bool {
        guard let viewport = frame(area), !viewport.contains(target) else { return false }
        var pending = AX.children(area), seen = Set<AXReference>(), content = CGRect.null
        while let child = pending.popLast() {
            try RequestRuntime.check()
            guard seen.count < 5000 else { throw ServiceError(.accessibilityError, "Excessive scroll-area content") }
            guard seen.insert(AXReference(element: child)).inserted else { continue }
            let role = AX.string(child, kAXRoleAttribute as String) ?? ""
            if role == kAXScrollBarRole as String { continue }
            if let bounds = frame(child) { content = content.union(bounds) }
            if role != kAXScrollAreaRole as String && !ClickableGeometry.clips(role: role, actions: AX.actionNames(child)) {
                pending.append(contentsOf: AX.children(child))
            }
        }
        var changed = false
        if ClickableGeometry.valid(content) {
            for (attribute, vertical) in [(kAXVerticalScrollBarAttribute as String, true), (kAXHorizontalScrollBarAttribute as String, false)] {
                guard let bar = AX.axElement(AX.copy(area, attribute)),
                      (AX.copy(bar, kAXEnabledAttribute as String) as? Bool) != false else { continue }
                var settable: DarwinBoolean = false
                guard AXUIElementIsAttributeSettable(bar, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { continue }
                let value = (AX.copy(bar, kAXValueAttribute as String) as? NSNumber).map { CGFloat($0.doubleValue) }
                guard let next = ClickableGeometry.scrollValue(targetMin: vertical ? target.minY : target.minX,
                    targetMax: vertical ? target.maxY : target.maxX, visibleMin: vertical ? viewport.minY : viewport.minX,
                    visibleMax: vertical ? viewport.maxY : viewport.maxX, contentMin: vertical ? content.minY : content.minX,
                    contentMax: vertical ? content.maxY : content.maxX, value: value) else { continue }
                if AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: Double(next))) == .success { changed = true }
            }
        }
        if !changed {
            var settable: DarwinBoolean = false, rectangle = target
            if AXUIElementIsAttributeSettable(area, "AXMakeScreenRectVisible" as CFString, &settable) == .success,
               settable.boolValue, let value = AXValueCreate(.cgRect, &rectangle),
               AXUIElementSetAttributeValue(area, "AXMakeScreenRectVisible" as CFString, value) == .success { changed = true }
        }
        return changed
    }
    static func scrollToVisible(_ element: AXUIElement, frame: CGRect) throws -> Bool {
        let plan: [ScrollToVisiblePlan.Step<AXUIElement>]
        do {
            plan = try ScrollToVisiblePlan.collect(from: element, identity: { AXReference(element: $0) }, role: { node in
                try AX.onElement(node) {
                    guard let role = AX.string(node, kAXRoleAttribute as String) else {
                        throw ServiceError(.accessibilityError, "Control disappeared while checking visibility")
                    }
                    return role
                }
            }, actions: { node in try AX.onElement(node) { AX.actionNames(node) } }, settable: { node in
                try AX.onElement(node) {
                    var settable: DarwinBoolean = false
                    return AXUIElementIsAttributeSettable(node, "AXScrollToVisible" as CFString, &settable) == .success && settable.boolValue
                }
            }, parent: { node in try AX.onElement(node) { AX.axElement(AX.copy(node, kAXParentAttribute as String)) } }, checkpoint: RequestRuntime.check)
        } catch ScrollToVisiblePlan.Failure.cyclicAncestry {
            throw ServiceError(.accessibilityError, "Cyclic accessibility ancestry")
        }
        var changed = false
        for step in plan {
            try RequestRuntime.check()
            switch step {
            case .action(let node):
                let status = try AX.onElement(node) { AXUIElementPerformAction(node, "AXScrollToVisible" as CFString) }
                guard status == .success || status == .cannotComplete || status == .attributeUnsupported else {
                    throw ServiceError(.accessibilityError, "Failed to reveal text (\(status.rawValue))")
                }
                changed = true
            case .attribute(let node):
                let status = try AX.onElement(node) { AXUIElementSetAttributeValue(node, "AXScrollToVisible" as CFString, kCFBooleanTrue) }
                guard status == .success else { throw ServiceError(.accessibilityError, "Failed to reveal text (\(status.rawValue))") }
                changed = true
            case .scrollArea(let node):
                changed = try AX.onElement(node) { try scrollArea(node, target: frame) } || changed
            }
        }
        if changed {
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            repeat {
                try RequestRuntime.check()
                if (try? AX.onElement(element) { try point(element, chessApplication: nil, requireDisplay: false) }) != nil { break }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { break }
                try RequestRuntime.wait(min(0.025, remaining))
            } while true
        }
        return changed
    }

    static func nativePoint(_ element: AXUIElement, bundle: String) throws -> CGPoint? {
        let application: AXUIElement? = bundle == "com.apple.Chess"
            ? AXUIElementCreateApplication(try AppResolver.pid(for: bundle)) : nil
        return try AX.onElement(element) {
            if let application, let chess = try chessPoint(element, application: application) { return chess }
            guard let origin = AX.point(element, kAXPositionAttribute as String),
                  let size = AX.size(element, kAXSizeAttribute as String) else {
                throw ServiceError(.unknownError, "elementHasNoFrame")
            }
            return try point(element, chessApplication: nil, requireDisplay: false,
                             frameOverride: CGRect(origin: origin, size: size))
        }
    }

    /// The center of the part of the element that its clipping ancestors leave
    /// visible, for a scroll at an element whose own center is hidden.
    static func visiblePartCenter(_ element: AXUIElement) throws -> CGPoint? {
        try AX.onElement(element) {
            guard let elementFrame = frame(element) else { return nil }
            var clips: [CGRect] = []
            for ancestor in try ancestors(element) {
                let role = AX.string(ancestor, kAXRoleAttribute as String) ?? ""
                guard ClickableGeometry.clips(role: role, actions: AX.actionNames(ancestor)) else { continue }
                guard let clip = frame(ancestor) else { return nil }
                clips.append(clip)
            }
            return ClickableGeometry.visiblePartCenter(frame: elementFrame, clips: clips)
        }
    }

    /// Whether the element's center lies outside its window, after any reveal.
    static func isOutsideWindow(_ element: AXUIElement) throws -> Bool {
        try AX.onElement(element) {
            guard let window = try AX.window(of: element), !CFEqual(window, element), let windowFrame = frame(window),
                  let elementFrame = frame(element) else { return false }
            return ClickableGeometry.centerOutside(elementFrame, window: windowFrame)
        }
    }

    static func secondaryPosition(_ element: AXUIElement, bundle: String) throws -> SecondaryCursorPreparation.Position {
        do {
            return try SecondaryCursorPreparation.position(specialPoint: {
                guard bundle == "com.apple.Chess" else { return nil }
                let application = AXUIElementCreateApplication(try AppResolver.pid(for: bundle))
                return try AX.onElement(element) { try chessPoint(element, application: application) }
            }, frame: {
                try AX.onElement(element) {
                    guard let origin = AX.point(element, kAXPositionAttribute as String),
                          let size = AX.size(element, kAXSizeAttribute as String) else { return nil }
                    return CGRect(origin: origin, size: size)
                }
            }, scroll: { try scrollToVisible(element, frame: $0) }, visiblePoint: { frame in
                try AX.onElement(element) { try point(element, chessApplication: nil, requireDisplay: false, frameOverride: frame) }
            }, checkpoint: RequestRuntime.check)
        } catch SecondaryCursorPreparation.Failure.noFrame {
            throw ServiceError(.unknownError, "elementHasNoFrame")
        }
    }

    static func prepare(_ initial: AXUIElement, bundle: String, refresh: () throws -> AXUIElement) throws -> Target {
        try RequestRuntime.check()
        guard let window = try AX.window(of: initial) else { throw ServiceError(.accessibilityError, "Control has no target window") }
        let raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        guard raised == .success || raised == .actionUnsupported else { throw ServiceError(.accessibilityError, "Could not reveal target window") }
        let chessApplication: AXUIElement? = if bundle == "com.apple.Chess" {
            AXUIElementCreateApplication(try AppResolver.pid(for: bundle))
        } else { nil }
        var element = initial
        var location = try point(element, chessApplication: chessApplication)
        if location == nil {
            var revealed = false
            for ancestor in try ancestors(element) {
                try RequestRuntime.check()
                let actions = AX.actionNames(ancestor)
                if actions.contains("AXScrollToVisible"), AXUIElementPerformAction(ancestor, "AXScrollToVisible" as CFString) == .success { revealed = true; continue }
                if AX.string(ancestor, kAXRoleAttribute as String) == "AXCell" {
                    var settable: DarwinBoolean = false
                    if AXUIElementIsAttributeSettable(ancestor, "AXScrollToVisible" as CFString, &settable) == .success, settable.boolValue,
                       AXUIElementSetAttributeValue(ancestor, "AXScrollToVisible" as CFString, kCFBooleanTrue) == .success { revealed = true; continue }
                }
                if AX.string(ancestor, kAXRoleAttribute as String) == kAXScrollAreaRole as String,
                   let bounds = frame(element), try scrollArea(ancestor, target: bounds) { revealed = true }
            }
            guard revealed else { throw ServiceError(.accessibilityError, "Control is clipped and cannot be scrolled into view") }
            element = try refresh()
            let limit = ProcessInfo.processInfo.systemUptime + 0.5
            location = try point(element, chessApplication: chessApplication)
            while location == nil && ProcessInfo.processInfo.systemUptime < limit {
                try RequestRuntime.wait(0.025)
                location = try point(element, chessApplication: chessApplication)
            }
        }
        guard let location else {
            throw ServiceError(.accessibilityError, "Control has no visible clickable center after revealing it")
        }
        let pointer = try AXPointerTarget.forElement(element, hostPID: AppResolver.pid(for: bundle))
        try RequestRuntime.check()
        return Target(element: element, point: location, pointer: pointer)
    }
}
