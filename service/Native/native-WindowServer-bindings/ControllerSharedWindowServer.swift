import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// The 13-function initializer is shared. Disable, reenable and optional
/// capture each have an independent lazy initializer; resolution never invokes
/// a WindowServer function. Lock only lookup/publication, never a native call.
final class ControllerWindowServerFunctionStore: @unchecked Sendable {
    enum Required: Int, CaseIterable, Sendable {
        case main, register, remove, request, bounds, screenRect, location
        case queryFocus, releaseFocus, frontProcess, property, modifyNotifications, level
    }
    struct Loader: Sendable {
        let mandatory: @Sendable () -> [ControllerSoftLinkSymbol?]
        let disable: @Sendable () -> ControllerSoftLinkSymbol?
        let reenable: @Sendable () -> ControllerSoftLinkSymbol?
        let capture: @Sendable () -> ControllerSoftLinkSymbol?
        static var native: Self {
            .init(mandatory: {
                ControllerSoftLink.resolve(images: ControllerWindowServerSymbolRequests.images,
                    requests: ControllerWindowServerSymbolRequests.required,
                    salt: ControllerWindowServerSymbolRequests.salt, backend: ControllerSoftLinkDarwin())
            }, disable: { ControllerWindowServerSymbolRequests.resolveUpdate(reenable: false, using: ControllerSoftLinkDarwin()) },
               reenable: { ControllerWindowServerSymbolRequests.resolveUpdate(reenable: true, using: ControllerSoftLinkDarwin()) },
               capture: { ControllerWindowServerSymbolRequests.resolveCapture(using: ControllerSoftLinkDarwin()) })
        }
    }
    private let loader: Loader
    private let lock = NSLock()
    private var mandatoryValue: [ControllerSoftLinkSymbol]?
    private var disableValue: ControllerSoftLinkSymbol?
    private var reenableValue: ControllerSoftLinkSymbol?
    private var captureValue: ControllerSoftLinkSymbol?
    private var captureInitialized = false
    init(loader: Loader) { self.loader = loader }
    func required(_ slot: Required) -> ControllerSoftLinkSymbol {
        lock.lock(); defer { lock.unlock() }
        if mandatoryValue == nil { mandatoryValue = ControllerWindowServerSymbolRequests.require(loader.mandatory()) }
        return mandatoryValue![slot.rawValue]
    }
    func update(reenable: Bool) -> ControllerSoftLinkSymbol {
        lock.lock(); defer { lock.unlock() }
        if reenable {
            if let value = reenableValue { return value }
            guard let value = loader.reenable() else { preconditionFailure("Required reenable-update symbol is unavailable") }
            reenableValue = value; return value
        }
        if let value = disableValue { return value }
        guard let value = loader.disable() else { preconditionFailure("Required disable-update symbol is unavailable") }
        disableValue = value; return value
    }
    func capture() -> ControllerSoftLinkSymbol? {
        lock.lock(); defer { lock.unlock() }
        if !captureInitialized { captureValue = loader.capture(); captureInitialized = true }
        return captureValue
    }
}

struct ControllerWindowServerOperations: Sendable {
    typealias Callback = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
    typealias Main = @convention(c) () -> OpaquePointer?
    typealias Registration = @convention(c) (OpaquePointer?, Callback, UInt32, UnsafeMutableRawPointer?) -> CGError
    typealias Request = @convention(c) (OpaquePointer?, UnsafePointer<UInt32>, UInt32) -> Void
    typealias Bounds = @convention(c) (OpaquePointer?, UInt32, UnsafeMutablePointer<CGRect>) -> CGError
    typealias Location = @convention(c) (CGEvent, CGPoint) -> Void
    typealias Focus = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<DarwinBoolean>) -> Int32
    typealias Release = @convention(c) (UInt32) -> Int32
    typealias Front = @convention(c) (UnsafePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
    typealias Property = @convention(c) (OpaquePointer?, OpaquePointer?, CFString, CFTypeRef) -> CGError
    typealias Modify = @convention(c) (OpaquePointer?, Int32, Int32, Int32) -> Int32
    typealias Level = @convention(c) (OpaquePointer?, UInt32, Int32) -> CGError
    typealias Update = @convention(c) (OpaquePointer?) -> CGError
    typealias Capture = @convention(c) (OpaquePointer?, UnsafePointer<UInt32>, Int32, UInt32, CGRect) -> Unmanaged<CFArray>?
    let store: ControllerWindowServerFunctionStore
    static let native = Self(store: .init(loader: .native))
    private func function<T>(_ slot: ControllerWindowServerFunctionStore.Required, as type: T.Type) -> T {
        unsafeBitCast(store.required(slot).address, to: type)
    }
    func mainConnection() -> OpaquePointer? { function(.main, as: Main.self)() }
    func register(_ connection: OpaquePointer?, callback: Callback, event: UInt32, context: UnsafeMutableRawPointer?) -> CGError {
        function(.register, as: Registration.self)(connection, callback, event, context)
    }
    func remove(_ connection: OpaquePointer?, callback: Callback, event: UInt32, context: UnsafeMutableRawPointer?) -> CGError {
        function(.remove, as: Registration.self)(connection, callback, event, context)
    }
    func request(_ connection: OpaquePointer?, windows: UnsafePointer<UInt32>, count: UInt32) {
        function(.request, as: Request.self)(connection, windows, count)
    }
    func bounds(_ window: UInt32, connection: OpaquePointer?, output: UnsafeMutablePointer<CGRect>) -> CGError {
        function(.bounds, as: Bounds.self)(connection, window, output)
    }
    func screenRect(_ window: UInt32, connection: OpaquePointer?, output: UnsafeMutablePointer<CGRect>) -> CGError {
        function(.screenRect, as: Bounds.self)(connection, window, output)
    }
    func setLocation(_ event: CGEvent, _ point: CGPoint) { function(.location, as: Location.self)(event, point) }
    func queryFocus(_ process: UnsafeMutablePointer<ProcessSerialNumber>, flag: UnsafeMutablePointer<DarwinBoolean>) -> Int32 {
        function(.queryFocus, as: Focus.self)(process, flag)
    }
    func releaseFocus(_ token: UInt32) -> Int32 { function(.releaseFocus, as: Release.self)(token) }
    func setFront(_ process: UnsafePointer<ProcessSerialNumber>, window: UInt32, options: UInt32) -> CGError {
        function(.frontProcess, as: Front.self)(process, window, options)
    }
    func setProperty(_ connection: OpaquePointer?, owner: OpaquePointer?, key: CFString, value: CFTypeRef) -> CGError {
        function(.property, as: Property.self)(connection, owner, key, value)
    }
    func setCursorUpdatesFromBackground(_ enabled: Bool) -> CGError {
        let connection = mainConnection()
        return setProperty(connection, owner: connection, key: "SetsCursorInBackground" as CFString, value: NSNumber(value: enabled))
    }
    func modifyNotifications(_ value: Int32, connection: OpaquePointer?) -> Int32 {
        function(.modifyNotifications, as: Modify.self)(connection, value, 0, 0)
    }
    func setLevel(_ level: Int32, window: UInt32, connection: OpaquePointer?) -> CGError {
        function(.level, as: Level.self)(connection, window, level)
    }
    func disable(_ connection: OpaquePointer?) -> CGError {
        unsafeBitCast(store.update(reenable: false).address, to: Update.self)(connection)
    }
    func reenable(_ connection: OpaquePointer?) -> CGError {
        unsafeBitCast(store.update(reenable: true).address, to: Update.self)(connection)
    }
    var captureFunction: Capture? { store.capture().map { unsafeBitCast($0.address, to: Capture.self) } }
}
