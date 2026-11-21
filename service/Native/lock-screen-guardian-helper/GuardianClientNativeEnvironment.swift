import Foundation

@objc(SAILockScreenGuardianXPCProtocol)
protocol ExternalGuardianRemoteXPCProtocol {
    @objc(beginUnlockGuardForThreadID:withReply:) func begin(threadID:String,withReply:@escaping (NSError?)->Void)
    @objc(completeUnlockGuardForThreadID:didUnlock:) func complete(threadID:String,didUnlock:Bool)
    @objc(retainAutoUnlockedLeaseForThreadID:) func retainLease(threadID:String)
    @objc(releaseAutoUnlockedLeaseForThreadID:) func releaseLease(threadID:String)
}
// NSXPC invokes both blocks on its own queue. Build them in a nonisolated
// function so Swift does not infer a MainActor assertion from begin().
private enum GuardianNativeBeginCallbacks {
    nonisolated static func failed(_ reply:CheckedContinuation<Void,Error>)->@Sendable(any Error)->Void {
        {reply.resume(throwing:$0)}
    }
    nonisolated static func replied(_ reply:CheckedContinuation<Void,Error>)->@Sendable(NSError?)->Void {
        {error in if let error{reply.resume(throwing:error)}else{reply.resume()}}
    }
}
@MainActor final class GuardianNativeConnection:ExternalGuardianConnection {
    let value:NSXPCConnection
    init(endpoint:GuardianNativeEndpoint,receiver:ExternalGuardianCallbackReceiver){
        value=NSXPCConnection(listenerEndpoint:endpoint.value)
        value.remoteObjectInterface=NSXPCInterface(with:ExternalGuardianRemoteXPCProtocol.self)
        value.exportedInterface=NSXPCInterface(with:ExternalGuardianClientXPCProtocol.self)
        value.exportedObject=receiver
    }
    func setHandlers(invalidation:@escaping @Sendable ()->Void,interruption:@escaping @Sendable ()->Void){
        value.invalidationHandler=invalidation;value.interruptionHandler=interruption
    }
    func activate(){value.activate()}
    func begin(threadID:String)async throws {
        try await withCheckedThrowingContinuation{(reply:CheckedContinuation<Void,Error>) in
            guard let proxy=value.remoteObjectProxyWithErrorHandler(GuardianNativeBeginCallbacks.failed(reply)) as? ExternalGuardianRemoteXPCProtocol else{
                reply.resume(throwing:ExternalGuardianClientError.proxyUnavailable);return
            }
            proxy.begin(threadID:threadID,withReply:GuardianNativeBeginCallbacks.replied(reply))
        }
    }
    func complete(threadID:String,didUnlock:Bool,remoteError:@escaping @Sendable (any Error)->Void)throws {
        guard let proxy=value.remoteObjectProxyWithErrorHandler(remoteError) as? ExternalGuardianRemoteXPCProtocol else{throw ExternalGuardianClientError.proxyUnavailable}
        proxy.complete(threadID:threadID,didUnlock:didUnlock)
    }
    func sendLease(threadID:String,retain:Bool,remoteError:@escaping @Sendable (any Error)->Void)->Bool {
        guard let proxy=value.remoteObjectProxyWithErrorHandler(remoteError) as? ExternalGuardianRemoteXPCProtocol else{return false}
        if retain{proxy.retainLease(threadID:threadID)}else{proxy.releaseLease(threadID:threadID)}
        return true
    }
}
enum GuardianExecutable {
    static func url(in bundle:URL)->URL {
        bundle.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("Contents",isDirectory:true).appendingPathComponent("SharedSupport",isDirectory:true)
            .appendingPathComponent("AexLockScreenGuardian.app",isDirectory:true).appendingPathComponent("Contents",isDirectory:true)
            .appendingPathComponent("MacOS",isDirectory:true).appendingPathComponent("AexLockScreenGuardian")
    }
    static func launch(in bundle:URL,name:String)throws->Int32 {
        let executable=url(in:bundle)
        guard FileManager.default.isExecutableFile(atPath:executable.path(percentEncoded:false)) else{throw ExternalGuardianClientError.executableUnavailable(executable.path(percentEncoded:false))}
        let process=Process();process.executableURL=executable;process.arguments=[name]
        do{try process.run()}catch{throw ExternalGuardianClientError.spawn(error)}
        return process.processIdentifier
    }
}
@MainActor final class GuardianNativeEnvironment:ExternalGuardianEnvironment {
    typealias Endpoint=GuardianNativeEndpoint
    let bundleURL:URL
    private let prefix:String
    private let diagnostic:(ExternalGuardianDiagnostic,Int32?,(any Error)?)->Void
    init(bundle:Bundle,prefix:String="com.aex.computeruse.lock-screen-guardian.",
         diagnostic:@escaping(ExternalGuardianDiagnostic,Int32?,(any Error)?)->Void={_,_,_ in}){
        bundleURL=bundle.bundleURL;self.prefix=prefix;self.diagnostic=diagnostic
    }
    func rendezvousName()->String{prefix+UUID().uuidString}
    func register(name:String)throws->GuardianNativeRendezvous{try .init(name:name)}
    nonisolated func receive(port:UInt32)async throws->GuardianNativeEndpoint?{try GuardianNativeEndpointTransport.receive(port:port)}
    func launch(name:String)throws->Int32{try GuardianExecutable.launch(in:bundleURL,name:name)}
    func connection(endpoint:GuardianNativeEndpoint,receiver:ExternalGuardianCallbackReceiver)->GuardianNativeConnection{.init(endpoint:endpoint,receiver:receiver)}
    func report(_ diagnostic:ExternalGuardianDiagnostic,pid:Int32?,error:(any Error)?){self.diagnostic(diagnostic,pid,error)}
}
