import ApplicationServices
import Darwin
import Foundation

/// Global focus SPI; resolve lazily, only once a caller explicitly
/// queries/releases focus. Function storage is Sendable without a shared raw
/// dlopen handle or suppressing the Swift 6 concurrency checks.
struct ControllerGlobalFocusSPI: Sendable {
    typealias Query = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<DarwinBoolean>) -> Int32
    typealias ProcessPID = @convention(c) (UnsafePointer<ProcessSerialNumber>, UnsafeMutablePointer<Int32>) -> Int32
    typealias Release = @convention(c) (UInt32) -> Int32
    let query: Query?
    let processPID: ProcessPID?
    let release: Release?
    static func resolve() -> Self? {
        // Public GetProcessPID remains independent of the salted private table.
        let image = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL)
        let processPID = image.flatMap { dlsym($0, "GetProcessPID") }.map { unsafeBitCast($0, to: ProcessPID.self) }
        return .init(query: { ControllerWindowServerOperations.native.queryFocus($0, flag: $1) },
            processPID: processPID, release: { ControllerWindowServerOperations.native.releaseFocus($0) })
    }
    func observe() -> ControllerGlobalFocusObservation? {
        guard let query,let processPID else{return nil}
        var psn=ProcessSerialNumber(highLongOfPSN:0,lowLongOfPSN:0),flag=DarwinBoolean(false),pid:Int32=0
        let queryStatus=query(&psn,&flag)
        let processStatus=processPID(&psn,&pid)
        return .init(queryStatus:queryStatus,processStatus:processStatus,pid:pid,flag:flag.boolValue)
    }
}
