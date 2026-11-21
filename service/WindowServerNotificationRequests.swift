import CoreGraphics
import Darwin
import Foundation

/// CGSRequestNotificationsForWindows replaces the connection's complete list.
/// Share leases across native consumers so one owner cannot erase another's IDs.
final class WindowServerNotificationRequests: @unchecked Sendable {
    struct API: Sendable {
        let request: @Sendable (Int32, [UInt32]) -> Int32
    }
    final class Lease: @unchecked Sendable {
        private let owner: WindowServerNotificationRequests
        private let connection: Int32
        private let token: UInt
        fileprivate init(owner: WindowServerNotificationRequests, connection: Int32, token: UInt) {
            self.owner=owner;self.connection=connection;self.token=token
        }
        deinit { owner.remove(connection:connection,token:token) }
    }

    static let shared=WindowServerNotificationRequests(api:.native)
    private let lock=NSLock()
    private let api: API
    private var next: UInt=0
    private var entries=[Int32:[UInt:Set<UInt32>]]()

    init(api: API) { self.api=api }

    /// Some observers deliberately retain registrations after a
    /// native failure. Other callers require success and roll back atomically.
    func acquire(connection: Int32, windows: [UInt32], requireSuccess: Bool) -> Lease? {
        let token: UInt?=lock.withLock {
            next += 1
            let token=next
            entries[connection,default:[:]][token]=Set(windows)
            let status=api.request(connection,windowIDs(connection))
            if requireSuccess && status != 0 {
                entries[connection]?[token]=nil
                if entries[connection]?.isEmpty==true { entries[connection]=nil }
                _=api.request(connection,windowIDs(connection))
                return nil
            }
            return token
        }
        return token.map { Lease(owner:self,connection:connection,token:$0) }
    }

    private func remove(connection: Int32, token: UInt) {
        lock.withLock {
            guard entries[connection]?.removeValue(forKey:token) != nil else { return }
            if entries[connection]?.isEmpty==true { entries[connection]=nil }
            _=api.request(connection,windowIDs(connection))
        }
    }

    /// Called only while holding lock; native replacement and ownership stores
    /// must remain serialized across concurrent acquisitions and destruction.
    private func windowIDs(_ connection: Int32) -> [UInt32] {
        (entries[connection]?.values.reduce(into:Set<UInt32>()) { $0.formUnion($1) } ?? []).sorted()
    }
}

extension WindowServerNotificationRequests.API {
    static var native: Self {
        .init { connection, windows in
            guard let request=NativeWindowNotificationRequest.function,
                  let count=UInt32(exactly:windows.count) else { return -1 }
            return windows.withUnsafeBufferPointer { request(connection,$0.baseAddress,count) }
        }
    }
}

private enum NativeWindowNotificationRequest {
    typealias Function = @convention(c) (Int32,UnsafePointer<UInt32>?,UInt32) -> Int32
    static let function: Function? = {
        guard let library=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY|RTLD_LOCAL),
              let symbol=dlsym(library,"CGSRequestNotificationsForWindows") ?? dlsym(library,"_CGSRequestNotificationsForWindows") else { return nil }
        return unsafeBitCast(symbol,to:Function.self)
    }()
}
