import CoreGraphics
import Darwin
import Foundation

/// Pure injected compatibility policy for explicit external adapters. Native
/// CGWindow observations use ControllerWindowNativeProducer's raw replacement
/// request; this helper has no native singleton or SPI function pointer.
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

