import Foundation

enum ExternalGuardianClientError:Error,LocalizedError {
    case registration(any Error)
    case spawn(any Error)
    case executableUnavailable(String)
    case endpointUnavailable
    case proxyUnavailable
    case connectionEnded
    var errorDescription:String? {
        switch self {
        case .registration(let error):return "Could not register the lock-screen Guardian Mach bootstrap rendezvous error=\(String(reflecting:error))."
        case .spawn(let error):return "Could not spawn the lock-screen Guardian process error=\(String(reflecting:error))."
        case .executableUnavailable(let path):return "The lock-screen Guardian executable is unavailable at \(path)."
        case .endpointUnavailable:return "Could not receive the lock-screen Guardian XPC endpoint."
        case .proxyUnavailable:return "Could not construct a lock-screen Guardian XPC proxy."
        case .connectionEnded:return "The lock-screen Guardian XPC connection ended before the guarded unlock completed."
        }
    }
}
enum ExternalGuardianDiagnostic:Sendable {case connected,interrupted,remoteCommandError,missingConnection,invalidProxy}

@objc(SAILockScreenGuardianClientXPCProtocol)
protocol ExternalGuardianClientXPCProtocol {
    @objc(lockScreenGuardianDetectedPhysicalInput) func detectedPhysicalInput()
}
private final class ExternalGuardianCallbackCell:@unchecked Sendable {
    private let lock=NSLock()
    private var callback:(@Sendable ()->Void)?
    init(_ callback:@escaping @Sendable ()->Void){self.callback=callback}
    func fire(){lock.lock();let callback=callback;lock.unlock();callback?()}
    func clear(){lock.lock();let previous=callback;callback=nil;lock.unlock();withExtendedLifetime(previous){}}
}
@MainActor final class ExternalGuardianCallbackReceiver:NSObject,ExternalGuardianClientXPCProtocol {
    nonisolated private let callback:ExternalGuardianCallbackCell
    init(_ callback:@escaping @Sendable ()->Void){self.callback = .init(callback)}
    nonisolated func detectedPhysicalInput(){callback.fire()}
    // NSObject ivar cleanup can follow the isolated Swift body on its own
    // thread. Drop the callback explicitly here to keep it isolated.
    isolated deinit {callback.clear()}
}
@MainActor protocol ExternalGuardianRendezvous:AnyObject {
    var receivePort:UInt32{get}
    func invalidate()
}
@MainActor protocol ExternalGuardianConnection:AnyObject,Sendable {
    func setHandlers(invalidation:@escaping @Sendable ()->Void,interruption:@escaping @Sendable ()->Void)
    func activate()
    func begin(threadID:String)async throws
    func complete(threadID:String,didUnlock:Bool,remoteError:@escaping @Sendable (any Error)->Void)throws
    func sendLease(threadID:String,retain:Bool,remoteError:@escaping @Sendable (any Error)->Void)->Bool
}
@MainActor protocol ExternalGuardianEnvironment:Sendable {
    associatedtype Rendezvous:ExternalGuardianRendezvous
    associatedtype Connection:ExternalGuardianConnection
    associatedtype Endpoint:Sendable
    func rendezvousName()->String
    func register(name:String)throws->Rendezvous
    nonisolated func receive(port:UInt32)async throws->Endpoint?
    func launch(name:String)throws->Int32
    func connection(endpoint:Endpoint,receiver:ExternalGuardianCallbackReceiver)->Connection
    func report(_ diagnostic:ExternalGuardianDiagnostic,pid:Int32?,error:(any Error)?)
}
