import AppKit
import ApplicationServices
import Darwin

// Global keyboard-focus SPI, resolved through ControllerGlobalFocusSPI.
// A receiver's AXFrontmost/isActive
// state is independent of the WindowServer's real keyboard-focus owner.
enum KeyboardFocusSPI {
    private static let nativeAPI = ControllerGlobalFocusSPI.resolve()
    static func releaseFocus(token: UInt32) -> Bool { releaseFocus(token: token, using: nativeAPI) }
    static func releaseFocus(token: UInt32, using api: ControllerGlobalFocusSPI?) -> Bool { api?.release?(token) == 0 }

    struct Observation {
        let queryStatus: Int32
        let processStatus: Int32
        let pid: Int32
        let flag: Bool
        var resolvedPID: Int32? { queryStatus == 0 && processStatus == 0 ? pid : nil }
    }
    static var available: Bool { isAvailable(nativeAPI) }
    static func isAvailable(_ api: ControllerGlobalFocusSPI?) -> Bool { api?.query != nil && api?.processPID != nil }
    static func observe() -> Observation? { observe(using: nativeAPI) }
    static func observe(using api: ControllerGlobalFocusSPI?) -> Observation? {
        guard let value = api?.observe() else { return nil }
        return .init(queryStatus: value.queryStatus, processStatus: value.processStatus, pid: value.pid, flag: value.flag)
    }

    // This is the regular-app branch of the focus check, not the full global
    // preventer. View-service/auxiliary mapping and its persistent state still
    // need their own adapter; nil preserves the existing fallback in callers.
    static func regularAppFocused(_ pid: Int32) -> Bool? {
        guard let focused = observe()?.resolvedPID,
              let app = NSRunningApplication(processIdentifier: focused),
              app.activationPolicy != .prohibited else { return nil }
        return focused == pid
    }
}
