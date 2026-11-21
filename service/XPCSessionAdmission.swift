import Foundation

enum XPCSessionAdmission {
    // Full access is an endpoint capability. Only the foreground-subscription-only
    // session is restricted to the PID that opened it.
    static func permits(foregroundOnly: Bool, senderPID: Int32, candidatePID: @autoclosure () -> Int32) -> Bool {
        !foregroundOnly || senderPID == candidatePID()
    }
}
