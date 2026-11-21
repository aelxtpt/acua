import Foundation
import CoreGraphics
import Darwin

/// CGWindow observer for System Settings windows. Native return codes do not control
/// registration lifetime; delivery prefers a live record, then the initial one.
final class SettingsWindowServerObservation: @unchecked Sendable {
    typealias Handler = @Sendable (SystemSettingsWindowRecord,UInt8) -> Void
    struct API: Sendable {
        let connection: @Sendable () -> UInt
        let query: @Sendable (UInt32) -> SystemSettingsWindowRecord?
        let register: @Sendable (UInt,UInt32,UInt) -> Int32
        let remove: @Sendable (UInt,UInt32,UInt) -> Int32
        let request: @Sendable (UInt,[UInt32]) -> Void
    }
    final class Registry: @unchecked Sendable {
        struct Entry: Sendable {
            let initial: [UInt32:SystemSettingsWindowRecord]
            let query: @Sendable (UInt32) -> SystemSettingsWindowRecord?
            let handler: Handler
        }
        private let lock=NSLock()
        private var next: UInt
        private var entries=[UInt:Entry]()
        init(lastToken: UInt = 0) { next=lastToken }
        func insert(_ entry: Entry) -> UInt {
            lock.withLock { next += 1;entries[next]=entry;return next }
        }
        func remove(_ token: UInt) { _ = lock.withLock { entries.removeValue(forKey:token) } }
        func deliver(rawEvent: UInt32, window: UInt32?, context: UInt) {
            guard let event=SettingsWindowServerObservation.ordinal(rawEvent),let window,context != 0,
                  let entry=lock.withLock({ entries[context] }) else { return }
            // Query outside the registry lock. The retained entry permits an
            // already in-flight callback to finish after registry removal.
            if let record=entry.query(window) ?? entry.initial[window] { entry.handler(record,event) }
        }
    }
    static let shared=Registry()
    let token: UInt
    private let events: [UInt8]
    private let api: API
    private let registry: Registry
    init(windowIDs: [UInt32], events: [UInt8], api: API, registry: Registry = shared, handler: @escaping Handler) {
        var initial=[UInt32:SystemSettingsWindowRecord]()
        for identifier in windowIDs {
            if identifier != 0,let record=api.query(identifier) { initial[identifier]=record }
            else { initial.removeValue(forKey:identifier) }
        }
        self.api=api;self.registry=registry;self.events=events
        token=registry.insert(.init(initial:initial,query:api.query,handler:handler))
        let connection=api.connection()
        for event in events { _ = api.register(connection,Self.rawValue(event),token) }
        api.request(connection,windowIDs)
    }
    deinit {
        registry.remove(token)
        let connection=api.connection()
        for event in events { _ = api.remove(connection,Self.rawValue(event),token) }
        // Removal does not re-request a union or clear the connection list.
    }
    func trackerLifetime() -> SystemSettingsWindowObservation { .init { [self] in _ = self } }
    static func ordinal(_ raw: UInt32) -> UInt8? {
        if (800...816).contains(raw) { return UInt8(raw-800) }
        if (1325...1328).contains(raw) { return UInt8(raw-1325+17) }
        return nil
    }
    static func receiveRawEvent(_ event: UInt32,payload: UnsafeRawPointer?,context: UnsafeMutableRawPointer?,registry: Registry = shared) {
        guard ordinal(event) != nil,let payload,let context else { return }
        registry.deliver(rawEvent:event,window:payload.loadUnaligned(as:UInt32.self),context:UInt(bitPattern:context))
    }
    static func rawValue(_ ordinal: UInt8) -> UInt32 {
        precondition(ordinal < 21)
        return ordinal < 17 ? UInt32(ordinal)+800:UInt32(ordinal)-17+1325
    }
}

// Native Settings tracking uses SettingsWindowNativeProducer and the shared
// controller registry. This injected facade has no separate native SPI table.
extension SystemSettingsWindowRecord {
    static func nativeDescription(_ identifier: UInt32) -> Self? {
        guard identifier != 0 else { return nil }
        var value=UnsafeRawPointer(bitPattern:UInt(identifier))
        let identifiers=CFArrayCreate(nil,&value,1,nil)!
        guard let rows=CGWindowListCreateDescriptionFromArray(identifiers) as? [[String:Any]],let row=rows.first else { return nil }
        return Self(info:row)
    }
}
