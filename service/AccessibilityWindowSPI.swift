import ApplicationServices
import Darwin

enum AccessibilityWindowSPI {
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
    private typealias GetPID = @convention(c) (AXUIElement, UnsafeMutablePointer<Int32>) -> AXError
    private static let image = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL)
    // Look up both Mach-O spellings, with and without the leading underscore.
    private static let windowFunction: GetWindow? = {
        guard let image else { return nil }
        for name in ["AXUIElementGetWindow", "_AXUIElementGetWindow"] {
            if let symbol = dlsym(image, name) { return unsafeBitCast(symbol, to: GetWindow.self) }
        }
        return nil
    }()
    private static let pidFunction: GetPID? = {
        guard let image else { return nil }
        for name in ["AXUIElementGetActualPid", "_AXUIElementGetActualPid"] {
            if let symbol = dlsym(image, name) { return unsafeBitCast(symbol, to: GetPID.self) }
        }
        return nil
    }()
    static var available: Bool { windowFunction != nil && pidFunction != nil }

    static func windowID(_ element: AXUIElement) throws -> UInt32 {
        guard let function = windowFunction else { throw ServiceError(.accessibilityError, "Accessibility window ID API is unavailable") }
        var id: UInt32 = 0
        let error = function(element, &id)
        guard error == .success, id != 0 else { throw ServiceError(.accessibilityError, "Could not resolve accessibility window ID (\(error.rawValue))") }
        return id
    }
    static func actualPID(_ element: AXUIElement) throws -> Int32 {
        guard let function = pidFunction else { throw ServiceError(.accessibilityError, "Accessibility process ID API is unavailable") }
        var pid: Int32 = 0
        let error = function(element, &pid)
        guard error == .success, pid > 0 else { throw ServiceError(.accessibilityError, "Could not resolve accessibility process ID (\(error.rawValue))") }
        return pid
    }
}
