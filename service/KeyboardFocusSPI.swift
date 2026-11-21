import AppKit
import ApplicationServices
import Darwin

// Private CPS keyboard-focus SPI, resolved under both symbol spellings.
// A receiver's AXFrontmost/isActive state is independent of the
// WindowServer's real keyboard-focus owner.
enum KeyboardFocusSPI {
    private typealias Query = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<DarwinBoolean>) -> Int32
    private typealias ProcessPID = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias Release = @convention(c) (UInt32) -> Int32
    private static let image = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL)
    private static let query: Query? = {
        guard let image else { return nil }
        for name in ["CPSGetKeyFocusProcess", "_CPSGetKeyFocusProcess"] {
            if let symbol = dlsym(image, name) { return unsafeBitCast(symbol, to: Query.self) }
        }
        return nil
    }()
    // Public C API; the SDK marks
    // its Swift declaration unavailable, while the C entry point still exists.
    private static let processPID: ProcessPID? = {
        guard let image, let symbol = dlsym(image, "GetProcessPID") else { return nil }
        return unsafeBitCast(symbol, to: ProcessPID.self)
    }()
    private static let release: Release? = {
        guard let image else { return nil }
        // Try both Mach-O spellings.
        for name in ["CPSReleaseKeyFocusWithID", "_CPSReleaseKeyFocusWithID"] {
            if let symbol = dlsym(image, name) { return unsafeBitCast(symbol, to: Release.self) }
        }
        return nil
    }()
    static func releaseFocus(token: UInt32) -> Bool { release?(token) == 0 }

    struct Observation {
        let queryStatus: Int32
        let processStatus: Int32
        let pid: Int32
        let flag: Bool
        var resolvedPID: Int32? { queryStatus == 0 && processStatus == 0 ? pid : nil }
    }
    static var available: Bool { query != nil && processPID != nil }
    static func observe() -> Observation? {
        guard let query, let processPID else { return nil }
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        var flag = DarwinBoolean(false), pid: Int32 = 0
        let status = query(&psn, &flag)
        // Attempt GetProcessPID even if the first call fails.
        let processStatus = processPID(&psn, &pid)
        return Observation(queryStatus: status, processStatus: processStatus, pid: pid, flag: flag.boolValue)
    }

    // This is the regular-app branch, not the full global
    // preventer. View-service/auxiliary mapping and its persistent state still
    // need their own adapter; nil preserves the existing fallback in callers.
    static func regularAppFocused(_ pid: Int32) -> Bool? {
        guard let focused = observe()?.resolvedPID,
              let app = NSRunningApplication(processIdentifier: focused),
              app.activationPolicy != .prohibited else { return nil }
        return focused == pid
    }
}
