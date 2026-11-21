// Remaining native branch of 0x100757B28. The previous mapped application's
// focused-element ancestry determines whether to release the current token or
// asynchronously repair the previous host. This does not invent focus tokens.
enum HostedFocusRepair {
    enum ProcessKind { case application, service }

    static func perform(releaseTheft: Bool, inspectViewService: Bool,
                        previousAppPID: Int32, previousAppProtected: Bool,
                        focusedProcess: () -> ProcessKind?,
                        release: () -> Bool, repair: (Int32) -> Void) -> Bool {
        if releaseTheft { return release() }
        guard inspectViewService, let kind = focusedProcess(), !previousAppProtected else { return false }
        switch kind {
        case .application: return release()
        case .service: repair(previousAppPID); return false
        }
    }
}
