import ApplicationServices
import Darwin

struct ControllerNativeAttention: Sendable {
    typealias Process = @convention(c) (Int32, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32
    typealias Attention = @convention(c) (UnsafePointer<ProcessSerialNumber>, Bool) -> Int32
    let process: Process
    let attention: Attention
    static func resolve() -> Self? {
        guard let image = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        func symbol(_ name: String) -> UnsafeMutableRawPointer? { dlsym(image, name) ?? dlsym(image, "_" + name) }
        guard let process = symbol("GetProcessForPID"), let attention = symbol("SetApplicationDesiresAttention") else { return nil }
        return .init(process: unsafeBitCast(process, to: Process.self), attention: unsafeBitCast(attention, to: Attention.self))
    }
    func clear(_ pid: Int32) {
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: 0)
        guard process(pid, &psn) == 0 else { return }
        _ = attention(&psn, false)
    }
}
