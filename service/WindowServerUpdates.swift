import AppKit
import Darwin

// SkyLight symbols used: SLSDisableUpdate, SLSReenableUpdate and
// CGSMainConnectionID. The connection ID is passed as Int32.
enum WindowServerUpdates {
    private typealias Main = @convention(c) () -> Int32
    private typealias Update = @convention(c) (Int32) -> Int32
    private static let image = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL)
    private static func symbol(_ names: [String]) -> UnsafeMutableRawPointer? {
        guard let image else { return nil }
        for name in names { if let value = dlsym(image, name) { return value } }
        return nil
    }
    private static let main: Main? = symbol(["CGSMainConnectionID", "_CGSMainConnectionID"]).map { unsafeBitCast($0, to: Main.self) }
    private static let disable: Update? = symbol(["SLSDisableUpdate", "_SLSDisableUpdate"]).map { unsafeBitCast($0, to: Update.self) }
    private static let reenable: Update? = symbol(["SLSReenableUpdate", "_SLSReenableUpdate"]).map { unsafeBitCast($0, to: Update.self) }
    private static let lock = NSLock()
    private static var count = 0
    static var activeLeaseCount: Int { lock.lock(); defer { lock.unlock() }; return count }

    final class Lease {
        private let lock = NSLock()
        private var connection: Int32?
        fileprivate init() throws {
            guard let main, let disable, reenable != nil else {
                throw ServiceError(.accessibilityError, "WindowServer update APIs are unavailable")
            }
            let id = main()
            guard disable(id) == 0 else {
                _ = reenable?(id)
                throw ServiceError(.accessibilityError, "Could not suspend WindowServer updates")
            }
            connection = id
            WindowServerUpdates.lock.lock(); count += 1; WindowServerUpdates.lock.unlock()
        }
        func finish() {
            lock.lock(); let id = connection; connection = nil; lock.unlock()
            guard let id else { return }
            _ = reenable?(id)
            WindowServerUpdates.lock.lock(); count -= 1; WindowServerUpdates.lock.unlock()
        }
        deinit { finish() }
    }
    static func pause() throws -> Lease { try Lease() }
}
