import AppKit
import ApplicationServices

/// Immutable retained OS handles are shared across the observer tasks;
/// mutating Swift state belongs to the locked ordering owner, not these handles.
struct ControllerOrderingApplication: @unchecked Sendable { let application: NSRunningApplication }
struct ControllerOrderingAXWindow: @unchecked Sendable { let element: AXUIElement }

enum ControllerWindowOrderingNative {
    typealias Ordering = ControllerWindowOrdering<ControllerOrderingApplication, ControllerOrderingAXWindow>
    struct RaiseFailure: Error { let status: AXError }

    ///Concrete read/raise operations. The exact CGWindow.EventStream/Observer
    ///producers remain explicit required bindings, never a fabricated stream.
    static func environment(
        events: @escaping @Sendable ([UInt32], Int) -> Ordering.Source,
        workspace: @escaping @Sendable ([UInt32], @escaping @Sendable () -> Void) -> any ControllerWindowOrderingLease,
        log: @escaping @Sendable (Ordering.Log) -> Void) -> Ordering.Environment {
        .init(events: events,
            frontmostApplication: { NSWorkspace.shared.frontmostApplication.map { .init(application: $0) } },
            processIdentifier: { $0.application.processIdentifier },
            resolvePID: { RunningApplicationPID.resolve($0.application) },
            focusedWindow: { pid in
                let application = AXUIElementCreateApplication(pid)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &value) == .success,
                      let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
                return .init(element: unsafeBitCast(value, to: AXUIElement.self))
            }, windowID: { try ControllerWindowID.read($0.element) },
            windowOwner: { id in
                guard let description = WindowDescription.lookup(id) else { return nil }
                return (description[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            }, onScreenWindowIDs: { onScreenWindowIDs() },
            observeWorkspaceAddition: workspace,
            raise: { window in
                let status = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
                guard status == .success || status == .cannotComplete || status == .attributeUnsupported else {
                    throw RaiseFailure(status: status)
                }
            }, sleep: { try await ContinuousClock().sleep(for: $0) }, log: log)
    }

    static func onScreenWindowIDs() -> [UInt32] {
        // CGWindowListCreate with raw option 0x11, not CopyWindowInfo or a
        // sorted/filtered list. Its CFArray contains raw integer pointer values.
        ControllerOnScreenWindowIDs.read()
    }
}
