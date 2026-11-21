import Foundation

/// The two observation channels are independent;
/// queued main-actor callbacks outlive the subscription that scheduled them.
@MainActor
final class PIPGeometryObservation<CGHandle: AnyObject & Sendable, AXHandle: AnyObject & Sendable, Element: Equatable & Sendable> {
    struct Target: Sendable {
        let pid: Int32
        let application: Element
        let window: Element
    }
    typealias Delivery = @MainActor @Sendable (String) -> Void
    typealias Work = @MainActor @Sendable () -> Void
    struct Environment {
        let lookupWindow: @MainActor @Sendable (UInt32) -> UInt32?
        let observeCG: @MainActor (UInt32, [ControllerWindowServerEvent], @escaping @Sendable (ControllerWindowServerEvent) -> Void) -> CGHandle?
        let applicationWindow: @MainActor (UInt32) throws -> Target
        let createAX: @MainActor (Int32, @escaping @Sendable (Element, String, (any Sendable)?) -> Void) throws -> AXHandle
        let add: @MainActor (AXHandle, Element, String) -> Int32
        let start: @MainActor (AXHandle, QualityOfService) -> Void
        var schedule: @Sendable (@escaping Work) -> Void = { work in Task { @MainActor in work() } }
    }
    private let cg: CGHandle?
    private let ax: AXHandle?

    init?(windowID: UInt32, environment: Environment,
          geometryChanged: @escaping Delivery, sourceUnavailable: @escaping Delivery) {
        let schedule = environment.schedule
        let lookup = environment.lookupWindow
        if let observedID = lookup(windowID) {
            cg = environment.observeCG(observedID, [.didResize, .geometryDidChange, .isTerminated]) { event in
                let reason = Self.cgReason(event)
                schedule { (event == .isTerminated ? sourceUnavailable : geometryChanged)(reason) }
            }
        } else { cg = nil }

        var observation: AXHandle?
        // A fresh ApplicationWindow construction, even when the CG channel failed.
        if let target = try? environment.applicationWindow(windowID) {
            let targetWindow = target.window
            if let candidate = try? environment.createAX(target.pid, { element, name, info in
                guard let reason = Self.axReason(name) else { return }
                schedule {
                    // Retain delivered user info through the asynchronous decision.
                    withExtendedLifetime(info) {
                        switch name {
                        case "AXResized", "AXWindowResized": geometryChanged(reason)
                        case "AXUIElementDestroyed":
                            if element == targetWindow || lookup(windowID) == nil { sourceUnavailable(reason) }
                        default:
                            if lookup(windowID) == nil { sourceUnavailable(reason) }
                        }
                    }
                }
           }) {
                var registered = false
                for (element, names) in [(target.window, ["AXResized", "AXUIElementDestroyed"]),
                                          (target.application, ["AXWindowResized", "AXFocusedWindowChanged", "AXMainWindowChanged",
                                                                "AXWindowCreated", "AXSheetCreated", "AXUIElementDestroyed"])] {
                     for name in names {
                         let status = environment.add(candidate, element, name)
                         // AX registration treats notificationAlreadyRegistered as success.
                         if status == 0 || status == -25209 { registered = true }
                     }
                }
                if registered {
                     environment.start(candidate, .userInitiated)
                     observation = candidate
                }
            }
        }
        ax = observation
        if cg == nil && ax == nil { return nil }
    }

    nonisolated static func cgReason(_ event: ControllerWindowServerEvent) -> String {
        switch event {
        case .didResize: "CGWindow.didResize"
        case .geometryDidChange: "CGWindow.geometryDidChange"
        case .isTerminated: "CGWindow.isTerminated"
        default: "CGWindow.\(event.rawValue)"
        }
    }
    nonisolated static func axReason(_ name: String) -> String? {
        switch name {
        case "AXResized": "AX.resized"
        case "AXWindowResized": "AX.windowResized"
        case "AXFocusedWindowChanged": "AX.focusedWindowChanged"
        case "AXMainWindowChanged": "AX.mainWindowChanged"
        case "AXWindowCreated": "AX.windowCreated"
        case "AXSheetCreated": "AX.sheetCreated"
        case "AXUIElementDestroyed": "AX.uiElementDestroyed"
        default: nil
        }
    }
}
