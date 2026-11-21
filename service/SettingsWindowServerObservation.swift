import Foundation
import CoreGraphics
import Darwin

/// Window server observer. Native return codes do not control
/// registration lifetime; delivery prefers a live record, then the initial one.
final class SettingsWindowServerObservation: @unchecked Sendable {
    typealias Handler = @Sendable (SystemSettingsWindowRecord,UInt8) -> Void
    struct API: Sendable {
        let connection: @Sendable () -> Int32
        let query: @Sendable (UInt32) -> SystemSettingsWindowRecord?
        let register: @Sendable (Int32,UInt32,UInt) -> Int32
        let remove: @Sendable (Int32,UInt32,UInt) -> Int32
        let request: @Sendable (Int32,[UInt32]) -> Void
        var requestLifetime: (@Sendable (Int32,[UInt32]) -> SystemSettingsWindowObservation)?
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
    private let connection: Int32
    private let events: [UInt8]
    private let api: API
    private let registry: Registry
    private let requestLifetime: SystemSettingsWindowObservation?
    init(windowIDs: [UInt32], events: [UInt8], api: API, registry: Registry = shared, handler: @escaping Handler) {
        var initial=[UInt32:SystemSettingsWindowRecord]()
        for identifier in windowIDs {
            if identifier != 0,let record=api.query(identifier) { initial[identifier]=record }
            else { initial.removeValue(forKey:identifier) }
        }
        self.api=api;self.registry=registry;self.events=events
        token=registry.insert(.init(initial:initial,query:api.query,handler:handler))
        connection=api.connection()
        for event in events { _ = api.register(connection,Self.rawValue(event),token) }
        if let acquire=api.requestLifetime { requestLifetime=acquire(connection,windowIDs) }
        else { requestLifetime=nil;api.request(connection,windowIDs) }
    }
    deinit {
        registry.remove(token)
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

extension SettingsWindowServerObservation.API {
    static var native: Self {
        let functions=SettingsWindowServerFunctions.shared
        return .init(connection:{ functions.connection() },query:{ SystemSettingsWindowRecord.nativeDescription($0) },
            register:{ functions.register($0,SettingsWindowServerFunctions.callback,$1,UnsafeMutableRawPointer(bitPattern:$2)) },
            remove:{ functions.remove($0,SettingsWindowServerFunctions.callback,$1,UnsafeMutableRawPointer(bitPattern:$2)) },
            request:{ connection,windows in
                let count=UInt32(windows.count)
                windows.withUnsafeBufferPointer { functions.request(connection,$0.baseAddress,count) }
            },requestLifetime:{ connection,windows in
                // Native integration shares the connection-wide list with PIP.
                // Generic test handles use the direct request path instead.
                let lease=WindowServerNotificationRequests.shared.acquire(connection:connection,windows:windows,requireSuccess:false)!
                return .init { _ = lease }
            })
    }
}
private struct SettingsWindowServerFunctions: Sendable {
    typealias Callback = @convention(c) (UInt32,UnsafeRawPointer?,Int,UnsafeMutableRawPointer?) -> Void
    let connection: @convention(c) () -> Int32
    let register: @convention(c) (Int32,Callback,UInt32,UnsafeMutableRawPointer?) -> Int32
    let remove: @convention(c) (Int32,Callback,UInt32,UnsafeMutableRawPointer?) -> Int32
    let request: @convention(c) (Int32,UnsafePointer<UInt32>?,UInt32) -> Void
    static let callback: Callback = { event,payload,_,context in
        // The callback forwards the fourth argument and ignores payload length.
        SettingsWindowServerObservation.receiveRawEvent(event,payload:payload,context:context)
    }
    static let shared: Self = {
        let library=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL)!
        func symbol(_ name:String) -> UnsafeMutableRawPointer {
            (dlsym(library,name) ?? dlsym(library,"_"+name))!
        }
        return Self(connection:unsafeBitCast(symbol("CGSMainConnectionID"),to:(@convention(c) () -> Int32).self),
            register:unsafeBitCast(symbol("CGSRegisterConnectionNotifyProc"),to:(@convention(c) (Int32,Callback,UInt32,UnsafeMutableRawPointer?) -> Int32).self),
            remove:unsafeBitCast(symbol("CGSRemoveConnectionNotifyProc"),to:(@convention(c) (Int32,Callback,UInt32,UnsafeMutableRawPointer?) -> Int32).self),
            request:unsafeBitCast(symbol("CGSRequestNotificationsForWindows"),to:(@convention(c) (Int32,UnsafePointer<UInt32>?,UInt32) -> Void).self))
    }()
}
extension SystemSettingsWindowRecord {
    static func nativeDescription(_ identifier: UInt32) -> Self? {
        guard identifier != 0 else { return nil }
        var value=UnsafeRawPointer(bitPattern:UInt(identifier))
        let identifiers=CFArrayCreate(nil,&value,1,nil)!
        guard let rows=CGWindowListCreateDescriptionFromArray(identifiers) as? [[String:Any]],let row=rows.first else { return nil }
        return Self(info:row)
    }
}
