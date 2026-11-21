import ApplicationServices
import Darwin

enum ApplicationRegistrySPI {
    typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus
    typealias SetFrontProcess = @convention(c) (UnsafePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> OSStatus
    private typealias SetAttention = @convention(c) (UnsafePointer<ProcessSerialNumber>, Bool) -> OSStatus

    private static let image = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        RTLD_LAZY | RTLD_LOCAL)

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let image else { return nil }
        return dlsym(image, name) ?? dlsym(image, "_" + name)
    }

    static let processForPID = symbol("GetProcessForPID").map { unsafeBitCast($0, to: ProcessForPID.self) }
    // Both spellings (with and without the leading underscore) are looked up.
    static let setFrontProcess = symbol("CPSSetFrontProcessWithOptions").map { unsafeBitCast($0, to: SetFrontProcess.self) }
    private static let setAttention = symbol("SetApplicationDesiresAttention").map { unsafeBitCast($0, to: SetAttention.self) }

    @discardableResult
    static func clearAttention(for pid: pid_t) -> OSStatus? {
        guard let processForPID, let setAttention else { return nil }
        var process = ProcessSerialNumber()
        let status = processForPID(pid, &process)
        guard status == 0 else { return status }
        return setAttention(&process, false)
    }
}
