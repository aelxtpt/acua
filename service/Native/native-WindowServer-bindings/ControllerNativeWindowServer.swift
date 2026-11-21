import ApplicationServices
import Darwin

/// These preserve the complete connection pointer in X registers.
/// These functions are independent of the legacy Int32 update lease.
struct ControllerNativeWindowServer: Sendable {
    typealias MainConnection = @convention(c) () -> OpaquePointer?
    typealias Update = @convention(c) (OpaquePointer?) -> CGError
    typealias SetLocation = @convention(c) (CGEvent, CGPoint) -> Void
    let mainConnection: MainConnection
    let disable: Update
    let reenable: Update
    let setLocation: SetLocation
    static func resolve() -> Self? {
        .init(mainConnection: { ControllerWindowServerOperations.native.mainConnection() },
            disable: { ControllerWindowServerOperations.native.disable($0) },
            reenable: { ControllerWindowServerOperations.native.reenable($0) },
            setLocation: { ControllerWindowServerOperations.native.setLocation($0, $1) })
    }
    var bindings: ControllerFocusWindowServerBindings {
        .init(mainConnection: { mainConnection().map(UInt.init(bitPattern:)) ?? 0 },
            disableUpdates: { _ = disable(OpaquePointer(bitPattern: $0)) },
            reenableUpdates: { _ = reenable(OpaquePointer(bitPattern: $0)) },
            setWindowLocation: { setLocation($0.event, $1) })
    }
}
