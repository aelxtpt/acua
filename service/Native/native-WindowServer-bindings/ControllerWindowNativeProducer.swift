import CoreGraphics
import Darwin
import Foundation

/// The function types use OpaquePointer? for the connection,
/// CGError for registration and Void for the request; preserve the complete bits.
struct ControllerWindowServerFunctions: Sendable {
    typealias Callback = @convention(c) (UInt32, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
    typealias Connection = @convention(c) () -> OpaquePointer?
    typealias Registration = @convention(c) (OpaquePointer?, Callback, UInt32, UnsafeMutableRawPointer?) -> CGError
    typealias Request = @convention(c) (OpaquePointer?, UnsafePointer<UInt32>, UInt32) -> Void
    let connection: Connection
    let register: Registration
    let remove: Registration
    let request: Request

    /// Lazy shared thunks; constructing the producer never initializes SPI.
    static func resolve() -> Self? {
        .init(connection: { ControllerWindowServerOperations.native.mainConnection() },
            register: { ControllerWindowServerOperations.native.register($0, callback: $1, event: $2, context: $3) },
            remove: { ControllerWindowServerOperations.native.remove($0, callback: $1, event: $2, context: $3) },
            request: { ControllerWindowServerOperations.native.request($0, windows: $1, count: $2) })
    }
}

/// Concrete per-observer ABI, using the shared cache/dispatcher.
/// This direct request path must not be installed alongside a connection-wide
/// lease policy until all consumers are composed and validated together.
final class ControllerWindowNativeProducer: Sendable {
    typealias Registry = ControllerWindowEventRegistry<ControllerWindowDescription>
    let registry: Registry
    private let api: ControllerWindowServerFunctions
    private let callback: ControllerWindowServerFunctions.Callback

    init(api: ControllerWindowServerFunctions, registry: Registry,
         callback: ControllerWindowServerFunctions.Callback) {
        self.api = api; self.registry = registry; self.callback = callback
    }

    private static let nativeRegistry = Registry(lookup: { ControllerWindowDescription.lookup($0) })
    private static let nativeFunctions = ControllerWindowServerFunctions.resolve()
    private static let nativeCallback: ControllerWindowServerFunctions.Callback = { event, payload, length, context in
        nativeRegistry.deliver(rawEvent: event, payload: payload, byteCount: Int(length), token: UInt(bitPattern: context))
    }
    static func native() -> ControllerWindowNativeProducer? {
        guard let api = nativeFunctions else { return nil }
        return .init(api: api, registry: nativeRegistry, callback: nativeCallback)
    }

    func observe(windowIDs: [UInt32], events: [ControllerWindowServerEvent], handler: @escaping Registry.Handler) -> Observation {
        Observation(owner: self, windowIDs: windowIDs, events: events, handler: handler)
    }

    final class Observation: ControllerWindowOrderingLease, @unchecked Sendable {
        private let owner: ControllerWindowNativeProducer
        private let events: [ControllerWindowServerEvent]
        let token: UInt
        fileprivate init(owner: ControllerWindowNativeProducer, windowIDs: [UInt32],
                         events: [ControllerWindowServerEvent], handler: @escaping Registry.Handler) {
            self.owner = owner; self.events = events
            token = owner.registry.insert(windowIDs: windowIDs, handler: handler)
            let connection = owner.api.connection()
            let context = UnsafeMutableRawPointer(bitPattern: token)
            for event in events { _ = owner.api.register(connection, owner.callback, event.rawValue, context) }
            let count = UInt32(windowIDs.count)
            if windowIDs.isEmpty {
                // Pass valid array storage even for zero elements.
                var unused: UInt32 = 0
                withUnsafePointer(to: &unused) { owner.api.request(connection, $0, count) }
            } else {
                windowIDs.withUnsafeBufferPointer { owner.api.request(connection, $0.baseAddress!, count) }
            }
        }
        deinit {
            owner.registry.remove(token)
            let connection = owner.api.connection()
            for event in events {
                _ = owner.api.remove(connection, owner.callback, event.rawValue, UnsafeMutableRawPointer(bitPattern: token))
            }
        }
    }
}
