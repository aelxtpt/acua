import Foundation
import CoreGraphics

struct ControllerMouseEventTarget<Node> {
    let pid: Int32
    let element: Node?
    let accessibilityWindow: Node
    let windowID: UInt32
    let windowBounds: CGRect
    let windowUsesFlippedCoordinates: Bool = false
}

/// The payload of an event-targeting failure is a reason ordinal,
/// not a point or a localized message.
enum ControllerMouseTargetFailure: Error, Equatable {
    case windowUnavailable(UInt32)
    case unresolvedContext(reason: Int)
}

@MainActor protocol ControllerMouseEventTargetBackend {
    associatedtype Node
    func ordinaryPID(_ application: Node) throws -> Int32
    func actualPID(_ node: Node) throws -> Int32
    func windowID(_ node: Node) throws -> UInt32
    /// Only AX illegalArgument is converted to nil.
    func optionalWindowID(_ node: Node) throws -> UInt32?
    func children(_ node: Node) -> [Node]
    func parent(_ node: Node) -> Node?
    func role(_ node: Node) -> String
    func bundleIdentifier(_ application: Node) -> String?
    func frame(_ window: Node) -> CGRect?
    func processKind(_ pid: Int32) -> ControllerMouseProcessKind
    func missingContainingProcess()
    func frontWindowID(at point: CGPoint) -> UInt32?
    func systemElement(at point: CGPoint) throws -> Node?
    func windowBounds(_ id: UInt32) -> CGRect?
}

enum ControllerMouseProcessKind { case application, service, unavailable }

/// Receives the captured AX window and optional element. It does not
/// re-enumerate an app's windows or require that a backing window be onscreen.
@MainActor struct ControllerMouseEventTargeting<Backend: ControllerMouseEventTargetBackend> {
    let backend: Backend
    typealias Node = Backend.Node
    typealias Target = ControllerMouseEventTarget<Node>

    func target(at point: CGPoint, application: Node, window: Node, element: Node?) throws -> Target {
        let hostPID = try backend.ordinaryPID(application)
        let windowPID = try backend.actualPID(window)
        var hit = element
        let provisional: (pid: Int32, windowID: UInt32)?
        if windowPID == hostPID {
            if let element {
                let effective = backend.children(element).first ?? element
                guard let remote = try remoteWindow(effective, hostPID: hostPID) else {
                    return try hostTarget(hostPID, window: window, element: hit)
                }
                provisional = remote
            } else {
                if backend.bundleIdentifier(application)?.hasPrefix("com.apple.Safari") == true {
                    return try hostTarget(hostPID, window: window, element: nil)
                }
                provisional = nil
            }
        } else {
            provisional = (windowPID, try backend.windowID(window))
        }

        // The ID getter runs even when the physical window lookup returns nil.
        let front = backend.frontWindowID(at: point)
        let selectedID = try backend.windowID(window)
        if front == selectedID, let systemHit = try backend.systemElement(at: point) {
            hit = systemHit
            if let remote = try remoteWindow(systemHit, hostPID: hostPID) {
                return try remoteTarget(remote, window: window, element: hit)
            }
            return try hostTarget(hostPID, window: window, element: hit)
        }
        guard let provisional else { throw ControllerMouseTargetFailure.unresolvedContext(reason: 2) }
        // An unrefined remote target discards the app-local element. A fresh
        // system-wide hit above is retained, even when its target is remote.
        return try remoteTarget(provisional, window: window, element: nil)
    }

    private func hostTarget(_ pid: Int32, window: Node, element: Node?) throws -> Target {
        let id: UInt32
        // Drop the element's window-ID error and fall back to the selected
        // AX window. AX reports no window for elements of a
        // WebKit WebContent process (-25201), so a throwing read here made
        // every click on a web form field fail.
        if let element, let directID = try? backend.windowID(element) {
            if (try? backend.actualPID(element)) == pid { id = directID }
            else { id = try hostWindow(element, pid: pid) }
        } else { id = try backend.windowID(window) }
        return .init(pid: pid, element: element, accessibilityWindow: window, windowID: id,
            windowBounds: backend.frame(window) ?? .zero)
    }

    private func remoteTarget(_ target: (pid: Int32, windowID: UInt32), window: Node, element: Node?) throws -> Target {
        guard let bounds = backend.windowBounds(target.windowID) else {
            throw ControllerMouseTargetFailure.windowUnavailable(target.windowID)
        }
        return .init(pid: target.pid, element: element, accessibilityWindow: window,
            windowID: target.windowID, windowBounds: bounds)
    }

    private func hostWindow(_ element: Node, pid: Int32) throws -> UInt32 {
        for ancestor in AXParentChain(start: element, parent: backend.parent) {
            if (try? backend.actualPID(ancestor)) == pid { return try backend.windowID(ancestor) }
        }
        throw ControllerMouseTargetFailure.unresolvedContext(reason: 3)
    }

    private func remoteWindow(_ element: Node, hostPID: Int32) throws -> (pid: Int32, windowID: UInt32)? {
        // Stop at the first finished app/service, including an app that
        // belongs to another PID. That ordinary app must not become a remote.
        for ancestor in AXParentChain(start: element, parent: backend.parent) {
            guard let pid = try? backend.actualPID(ancestor) else { continue }
            switch backend.processKind(pid) {
            case .unavailable: continue
            case .application: return nil
            case .service:
                guard pid != hostPID else { return nil }
                return (pid, try remoteWindowID(ancestor))
            }
        }
        backend.missingContainingProcess()
        return nil
    }

    private func remoteWindowID(_ element: Node) throws -> UInt32 {
        for ancestor in AXParentChain(start: element, parent: backend.parent) {
            if let id = try backend.optionalWindowID(ancestor) { return id }
            if backend.role(ancestor) == "AXWindow" || backend.role(ancestor) == "AXSheet" { break }
        }
        throw ControllerMouseTargetFailure.unresolvedContext(reason: 1)
    }
}
