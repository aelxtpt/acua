import Foundation

private final class RuntimeProbeState: @unchecked Sendable {
    private let lock=NSLock()
    private var cancelledStorage=false,checkpointStorage=false
    private var callsStorage=0,finishedStorage=false
    func cancel(){lock.lock();cancelledStorage=true;lock.unlock()}
    func failCheckpoint(){lock.lock();checkpointStorage=true;lock.unlock()}
    var cancelled:Bool{lock.lock();defer{lock.unlock()};return cancelledStorage}
    var calls:Int{lock.lock();defer{lock.unlock()};return callsStorage}
    func finish(){lock.lock();finishedStorage=true;lock.unlock()}
    var finished:Bool{lock.lock();defer{lock.unlock()};return finishedStorage}
    func checkpoint() throws {
        lock.lock();callsStorage+=1;let fail=checkpointStorage;lock.unlock()
        if fail{throw ServiceError(.userIntervened,"Owned checkpoint stopped")}
    }
}
private struct RuntimeProbeFailure: Error {}

@main enum SelectedAsyncRequestRuntimeChecks {
    static func main() async throws {
        var rows=[[String:Any]]()
        func check(_ name:String,_ value:Bool){rows.append(["name":name,"passed":value]);if !value{print("FAIL "+name)}}
        func errorMessage(_ body:() throws->Void)->String? {
            do{try body();return nil}catch let error as ServiceError{return error.message}catch{return String(reflecting:error)}
        }
        func identity(_ pid:Int32)->SenderRequestContext {
            .init(senderPID:pid,responsibleIdentity:.init(team:"owned",signingID:"owned.sender.\(pid)",bundleID:nil,executable:nil),ancestorIdentities:[],clientMetadata:.socket)
        }
        let first=identity(11123),second=identity(22246)
        let empty=RequestRuntime.asynchronousScope()
        check("outside request has no peer or identity",RequestRuntime.peerPID==nil && RequestRuntime.senderContext==nil)
        let state=RuntimeProbeState()
        let scope=try RequestRuntime.withRequest([:],cancelled:{state.cancelled},senderContext:first){
            check("synchronous capture has requested identity",RequestRuntime.peerPID==first.senderPID && RequestRuntime.senderContext==first)
            return RequestRuntime.asynchronousScope()
        }
        check("capturing a scope does not retain thread-local request state",RequestRuntime.peerPID==nil && RequestRuntime.senderContext==nil)
        try await RequestRuntime.withAsyncScope(scope){
            await Task.yield()
            check("async suspension preserves peer and identity",RequestRuntime.peerPID==first.senderPID && RequestRuntime.senderContext==first)
            try RequestRuntime.check()
            let inherited=await Task {await Task.yield();return RequestRuntime.senderContext==first}.value
            check("structured child inherits async request context",inherited)
            let detached=await Task.detached {RequestRuntime.peerPID==nil && RequestRuntime.senderContext==nil}.value
            check("detached child does not accidentally borrow request identity",detached)
            let explicitlyBound=await Task.detached {await RequestRuntime.withAsyncScope(scope){await Task.yield();return RequestRuntime.senderContext==first}}.value
            check("explicitly bound detached child preserves context",explicitlyBound)
            await RequestRuntime.withAsyncScope(empty){
                await Task.yield()
                check("an explicitly empty nested async scope clears identity",RequestRuntime.peerPID==nil && RequestRuntime.senderContext==nil)
            }
            check("outer context restores after empty async scope",RequestRuntime.senderContext==first)
            do{try await RequestRuntime.withAsyncScope(empty){await Task.yield();throw RuntimeProbeFailure()}}catch is RuntimeProbeFailure{}
            check("outer context restores after throwing async scope",RequestRuntime.senderContext==first)
            try RequestRuntime.withRequest([:],peerPID:second.senderPID){
                check("different nested peer cannot inherit another sender identity",RequestRuntime.peerPID==second.senderPID && RequestRuntime.senderContext==nil)
            }
            try RequestRuntime.withRequest([:],peerPID:second.senderPID,senderContext:first){
                check("mismatched explicit sender identity is removed",RequestRuntime.peerPID==second.senderPID && RequestRuntime.senderContext==nil)
            }
            check("synchronous nested scopes restore async parent",RequestRuntime.senderContext==first)
            let mainContext=try await Task.detached {try await RequestRuntime.withAsyncScope(scope){
                try RequestRuntime.onMainThread {try RequestRuntime.check();return RequestRuntime.senderContext==first}
            }}.value
            check("main-queue bridge retains current async peer and identity",mainContext)
        }
        check("completed async scope leaves no peer on caller",RequestRuntime.peerPID==nil && RequestRuntime.senderContext==nil)
        let secondScope=try RequestRuntime.withRequest([:],senderContext:second){RequestRuntime.asynchronousScope()}
        let isolated=await withTaskGroup(of:Bool.self){group in
            for (captured,expected) in [(scope,first),(secondScope,second)]{
                group.addTask {await RequestRuntime.withAsyncScope(captured){
                    for _ in 0..<128 {await Task.yield();if RequestRuntime.senderContext != expected || RequestRuntime.peerPID != expected.senderPID{return false}}
                    return true
                }}
            }
            var passed=true;for await result in group{passed=passed && result};return passed
        }
        check("interleaved async requests never exchange sender context",isolated)
        let checkpoint=RuntimeProbeState()
        let checked=try RequestRuntime.withRequest([:],senderContext:first){
            try RequestRuntime.withCheckpoint({try checkpoint.checkpoint()}){RequestRuntime.asynchronousScope()}
        }
        let before=checkpoint.calls
        try await RequestRuntime.withAsyncScope(checked){
            await Task.yield();try RequestRuntime.check()
            check("session checkpoint survives async suspension",checkpoint.calls>before)
            checkpoint.failCheckpoint()
            check("checkpoint failure propagates after suspension",errorMessage{try RequestRuntime.check()}=="Owned checkpoint stopped")
        }
        let worker=try RequestRuntime.withRequest([:],cancelled:{state.cancelled},senderContext:first){RequestRuntime.workerScope()}
        state.cancel()
        await RequestRuntime.withAsyncScope(scope){
            await Task.yield()
            check("captured cancellation closure remains active",errorMessage{try RequestRuntime.check()}=="Request cancelled")
            check("nested request cannot clear inherited cancellation",errorMessage{try RequestRuntime.withRequest([:]){}}=="Request cancelled")
            check("cancelled async wait rejects before waiting for a semaphore",errorMessage{try RequestRuntime.wait(for:DispatchSemaphore(value:0),maximumSeconds:1)}=="Request cancelled")
        }
        try RequestRuntime.withWorkerScope(worker,cancelled:{false}){
            try RequestRuntime.check()
            check("capture worker keeps identity without retaining initiating connection cancellation",RequestRuntime.senderContext==first)
        }
        check("worker scope restores empty caller context",RequestRuntime.peerPID==nil && RequestRuntime.senderContext==nil)
        let parentDeadline=Date().addingTimeInterval(0.5).timeIntervalSince1970*1000
        let short=try RequestRuntime.withRequest(["deadlineUnixMilliseconds":parentDeadline],senderContext:first){RequestRuntime.asynchronousScope()}
        try await RequestRuntime.withAsyncScope(short){
            let nested=try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().addingTimeInterval(5).timeIntervalSince1970*1000]){RequestRuntime.asynchronousScope()}
            await RequestRuntime.withAsyncScope(nested){
                try? await Task.sleep(nanoseconds:650_000_000)
                check("long nested deadline cannot extend async parent deadline",errorMessage{try RequestRuntime.check()}=="Request deadline exceeded")
            }
        }
        check("deadline failure does not leak completed context",RequestRuntime.peerPID==nil && RequestRuntime.senderContext==nil)
        check("no serialization gates retained by scope tests",RequestRuntime.activeAppCount==0)
        let metadata=ComputerUseTelemetryContext.Snapshot(.init(model:"owned-model",sessionID:"owned-session",turnID:"owned-turn"))
        let bridged=try await Task.detached {
            try ComputerUseTelemetryContext.$current.withValue(metadata){
                try RequestRuntime.withRequest([:],senderContext:first){
                    try ControllerNativeRequestBridge.wait {
                        await Task.yield();try RequestRuntime.check()
                        return RequestRuntime.senderContext==first && ComputerUseTelemetryContext.snapshot()==metadata
                    }
                }
            }
        }.value
        check("actual native request bridge preserves async identity and turn metadata",bridged)
        let propagated=await Task.detached {()->Bool in
            do {
                let _:Int=try RequestRuntime.withRequest([:],senderContext:first){
                    try ControllerNativeRequestBridge.wait {await Task.yield();throw ServiceError(.accessibilityError,"Owned main actor failure")}
                }
                return false
            } catch let e as ServiceError{return e.code == .accessibilityError && e.message=="Owned main actor failure"}
            catch{return false}
        }.value
        check("actual native request bridge propagates async operation errors",propagated)
        let bridgeCancel=RuntimeProbeState()
        let cancelling=Task.detached {()->Bool in
            do {
                let _:Int=try RequestRuntime.withRequest([:],cancelled:{bridgeCancel.cancelled},senderContext:first){
                    try ControllerNativeRequestBridge.wait {
                        defer{bridgeCancel.finish()};try bridgeCancel.checkpoint()
                        try await Task.sleep(nanoseconds:5_000_000_000);return 42
                    }
                }
                return false
            }catch let e as ServiceError{return e.message=="Request cancelled"}catch{return false}
        }
        for _ in 0..<200 where bridgeCancel.calls==0{try await Task.sleep(nanoseconds:10_000_000)}
        check("controlled operation enters the actual native bridge",bridgeCancel.calls>0)
        bridgeCancel.cancel()
        check("actual bridge wait observes initiating request cancellation",await cancelling.value)
        for _ in 0..<200 where !bridgeCancel.finished{try await Task.sleep(nanoseconds:10_000_000)}
        check("actual bridge cancels its suspended async task during cleanup",bridgeCancel.finished)
        let bridgeDeadline=RuntimeProbeState()
        let expired=await Task.detached {()->Bool in
            do{
                let deadline=Date().addingTimeInterval(0.5).timeIntervalSince1970*1000
                let _:Int=try RequestRuntime.withRequest(["deadlineUnixMilliseconds":deadline],senderContext:first){
                    try ControllerNativeRequestBridge.wait {
                        defer{bridgeDeadline.finish()};try bridgeDeadline.checkpoint()
                        try await Task.sleep(nanoseconds:5_000_000_000);return 42
                    }
                }
                return false
            }catch let e as ServiceError{return e.message=="Request deadline exceeded"}catch{return false}
        }.value
        check("actual bridge respects initiating request deadline",expired)
        for _ in 0..<200 where !bridgeDeadline.finished{try await Task.sleep(nanoseconds:10_000_000)}
        check("deadline expiry cancels the actual bridge task",bridgeDeadline.calls>0 && bridgeDeadline.finished)
        check("bridge completion leaves no caller identity or metadata",RequestRuntime.peerPID==nil && ComputerUseTelemetryContext.snapshot().isEmpty)
        let passed=rows.allSatisfy{$0["passed"] as? Bool==true}
        let result:[String:Any]=["passed":passed,"cases":rows,"concurrent_yields_per_request":128,
            "actual_selected_RequestRuntime_source_used":true,"native_authentication_or_GUI_effects_executed":false,
            "scope":"Owned async context, deadline, cancellation and identity component checks; the whole transport is not exercised."]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        print("Selected async request context: \(rows.filter{$0["passed"] as? Bool==true}.count)/\(rows.count)")
        if !passed{exit(1)}
    }
}
