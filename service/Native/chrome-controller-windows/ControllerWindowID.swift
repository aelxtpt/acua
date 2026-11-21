import ApplicationServices
import Darwin

/// SPI fallback. Success with ID 0 is a value, not an AX error.
enum ControllerWindowID {
    enum Failure: Error, Equatable { case unavailable, accessibility(Int32) }
    private typealias Function = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
    private struct API: @unchecked Sendable {
        // Immutable C entry point with no captured Swift state. The system
        //framework image stays loaded, as with the existing native SPI reader.
        let function: Function
    }
    private static let api: API? = {
        guard let image = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        for name in ["AXUIElementGetWindow", "_AXUIElementGetWindow"] {
            if let symbol = dlsym(image, name) { return API(function: unsafeBitCast(symbol, to: Function.self)) }
        }
        return nil
    }()
    static var available: Bool { api != nil }

    static func read(operation: (inout UInt32) -> Int32?) throws -> UInt32 {
        var id: UInt32 = 0
        guard let status = operation(&id) else { throw Failure.unavailable }
        guard status == 0 else { throw Failure.accessibility(status) }
        return id
    }

    static func read(_ element: AXUIElement) throws -> UInt32 {
        try read { id in api.map { $0.function(element, &id).rawValue } }
    }
}
