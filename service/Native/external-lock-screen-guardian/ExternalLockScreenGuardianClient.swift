import Foundation

private enum ExternalGuardianOperationTask {
    nonisolated static func start(_ perform:@escaping @Sendable ()async throws->Bool)->Task<Bool,Error> {
        if #available(macOS 26.0,*){return Task.immediate(operation:perform)}
        return Task(operation:perform)
    }
}

@MainActor private final class ExternalGuardianWeakTarget<E:ExternalGuardianEnvironment> {
    weak var client:ExternalLockScreenGuardianClient<E>?
    nonisolated func receivedPhysicalInput(){Task{@MainActor [weak self] in self?.client?.physicalInputHandler?()}}
}

@MainActor final class ExternalLockScreenGuardianClient<Environment:ExternalGuardianEnvironment> {
    let environment:Environment
    let callbackReceiver:ExternalGuardianCallbackReceiver
    private let callbackTarget:ExternalGuardianWeakTarget<Environment>
    private let outbound=AsyncSerialQueue()
    var physicalInputHandler:(@MainActor ()->Void)?
    var connectionLossHandler:(@MainActor ()->Void)?
    private var activeUnlockTask:Task<Bool,Error>?
    private var connection:Environment.Connection?
    struct Snapshot:Equatable {let hasPhysicalHandler:Bool,hasLossHandler:Bool,hasActiveUnlockTask:Bool,hasConnection:Bool}
    var snapshot:Snapshot{.init(hasPhysicalHandler:physicalInputHandler != nil,hasLossHandler:connectionLossHandler != nil,
        hasActiveUnlockTask:activeUnlockTask != nil,hasConnection:connection != nil)}
    init(environment:Environment){
        self.environment=environment
        let target=ExternalGuardianWeakTarget<Environment>()
        callbackTarget=target;callbackReceiver=ExternalGuardianCallbackReceiver{target.receivedPhysicalInput()}
        target.client=self
    }
    func withUnlockGuard(threadID:String,perform:@escaping @Sendable ()async throws->Bool)async throws->Bool {
        try await outbound.sync{try await self.guarded(threadID:threadID,perform:perform)}
    }
    func withUnlockGuardOrFalse(threadID:String,perform:@escaping @Sendable ()async throws->Bool)async->Bool {
        (try? await withUnlockGuard(threadID:threadID,perform:perform)) ?? false
    }
    func retainAutoUnlockedLease(threadID:String){outbound.async{await self.sendLease(threadID:threadID,retain:true)}}
    func releaseAutoUnlockedLease(threadID:String){outbound.async{await self.sendLease(threadID:threadID,retain:false)}}
    private func guarded(threadID:String,perform:@escaping @Sendable ()async throws->Bool)async throws->Bool {
        let current=try await ensureConnection()
        try await current.begin(threadID:threadID)
        guard connection===current else{throw ExternalGuardianClientError.connectionEnded}
        let task=ExternalGuardianOperationTask.start(perform)
        activeUnlockTask=task
        do{
            let result=try await task.value
            try complete(threadID:threadID,didUnlock:result,on:current)
            activeUnlockTask=nil
            return result
        }catch{
            activeUnlockTask=nil
            try? complete(threadID:threadID,didUnlock:false,on:current)
            if error is CancellationError{throw ExternalGuardianClientError.connectionEnded}
            throw error
        }
    }
    private func ensureConnection()async throws->Environment.Connection {
        if let connection{return connection}
        let name=environment.rendezvousName()
        let rendezvous:Environment.Rendezvous
        do{rendezvous=try environment.register(name:name)}catch{throw ExternalGuardianClientError.registration(error)}
        defer{rendezvous.invalidate()}
        let port=rendezvous.receivePort,environment=environment
        let receive=Task.detached{try await environment.receive(port:port)}
        let pid:Int32
        do{pid=try environment.launch(name:name)}catch{receive.cancel();throw error}
        guard let endpoint=try await receive.value else{throw ExternalGuardianClientError.endpointUnavailable}
        let created=environment.connection(endpoint:endpoint,receiver:callbackReceiver)
        created.setHandlers(invalidation:{[weak self,weak created] in
            Task{@MainActor in guard let self,let created else{return};self.lost(created)}
        },interruption:{[weak self,weak created] in
            Task{@MainActor in
                guard let self,let created else{return}
                environment.report(.interrupted,pid:nil,error:nil);self.lost(created)
            }
        })
        created.activate();connection=created
        environment.report(.connected,pid:pid,error:nil)
        return created
    }
    private func lost(_ ended:Environment.Connection){
        // Cancel before the identity check, including for stale callbacks.
        activeUnlockTask?.cancel()
        guard connection===ended else{return}
        connection=nil;connectionLossHandler?()
    }
    private func complete(threadID:String,didUnlock:Bool,on captured:Environment.Connection)throws {
        guard connection != nil else{throw ExternalGuardianClientError.connectionEnded}
        let environment=environment
        try captured.complete(threadID:threadID,didUnlock:didUnlock){error in
            Task{@MainActor in environment.report(.remoteCommandError,pid:nil,error:error)}
        }
    }
    private func sendLease(threadID:String,retain:Bool){
        guard let connection else{environment.report(.missingConnection,pid:nil,error:nil);return}
        let environment=environment
        if !connection.sendLease(threadID:threadID,retain:retain,remoteError:{error in
            Task{@MainActor in environment.report(.remoteCommandError,pid:nil,error:error)}
        }){environment.report(.invalidProxy,pid:nil,error:nil)}
    }
    // Destruction is actor-isolated and only releases stored fields.
    isolated deinit {}
}
