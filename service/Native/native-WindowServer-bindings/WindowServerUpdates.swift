import AppKit
import Darwin

// Forward the entire opaque connection through X registers.
// Update symbols initialize independently from the mandatory 13-function table.
enum WindowServerUpdates {
    private typealias Main = @convention(c) () -> OpaquePointer?
    private typealias Update = @convention(c) (OpaquePointer?) -> CGError
    private static let main: Main = { ControllerWindowServerOperations.native.mainConnection() }
    private static let disable: Update = { ControllerWindowServerOperations.native.disable($0) }
    private static let reenable: Update = { ControllerWindowServerOperations.native.reenable($0) }
    private static let lock = NSLock()
    private static var count = 0
    static var activeLeaseCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    final class Lease {
        private let lock = NSLock()
        private var connection: UInt?
        fileprivate init() throws {
            let id = main()
            guard disable(id) == .success else {
                _ = reenable(id)
                throw ServiceError(.accessibilityError, "Could not suspend WindowServer updates")
            }
            connection = id.map(UInt.init(bitPattern:)) ?? 0
            WindowServerUpdates.lock.lock(); count += 1; WindowServerUpdates.lock.unlock()
        }
        func finish() {
            lock.lock(); let id = connection; connection = nil; lock.unlock()
            guard let id else { return }
            _ = reenable(OpaquePointer(bitPattern: id))
            WindowServerUpdates.lock.lock(); count -= 1; WindowServerUpdates.lock.unlock()
        }
        deinit { finish() }
    }
    static func pause() throws -> Lease { try Lease() }
}
