import CoreGraphics
import Darwin

enum ControllerOnScreenWindowIDs {
    private typealias Function = @convention(c) (UInt32, UInt32) -> Unmanaged<CFArray>?
    private struct API: @unchecked Sendable { let function: Function }
    private static let api: API? = {
        // This C API is intentionally unavailable in Swift's importer. Call it
        // through its actual C ABI and keep its Create ownership.
        guard let image = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL),
              let symbol = dlsym(image, "CGWindowListCreate") else { return nil }
        return API(function: unsafeBitCast(symbol, to: Function.self))
    }()
    static var available: Bool { api != nil }
    static func read(query: (UInt32, UInt32) -> Unmanaged<CFArray>?) -> [UInt32] {
        guard let result = query(0x11, 0) else { return [] }
        let windows = result.takeRetainedValue()
        return (0..<CFArrayGetCount(windows)).map {
            UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(windows, $0)))
        }
    }
    static func read() -> [UInt32] { read { api?.function($0, $1) } }
}
