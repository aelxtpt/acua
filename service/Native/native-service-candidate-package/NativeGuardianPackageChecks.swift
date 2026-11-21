import AppKit
import Darwin
import Foundation
import os

/// Exercise the packaged native helper's startup and idle IPC only. No guard is
/// begun and no lease is acquired: release of an unknown ID is a no-op.
@_silgen_name("cua_guardian_receive_audited_endpoint") private func receiveAuditedEndpoint(_ port:UInt32,_ sender:UnsafeMutablePointer<Int32>,_ error:UnsafeMutablePointer<UnsafeMutableRawPointer?>)->UnsafeMutableRawPointer?

@MainActor enum NativeGuardianPackageChecks {
    nonisolated private static func auditedEndpoint(_ port:UInt32)throws->(GuardianNativeEndpoint,Int32) {
        var sender:Int32=0,error:UnsafeMutableRawPointer?
        guard let raw=receiveAuditedEndpoint(port,&sender,&error) else {
            throw error.map{Unmanaged<NSError>.fromOpaque($0).takeRetainedValue()} ?? NSError(domain:"OwnedGuardianEndpointAudit",code:2)
        }
        return (.init(Unmanaged<NSXPCListenerEndpoint>.fromOpaque(raw).takeRetainedValue()),sender)
    }
    private enum Failure:Error {case endpoint,invalidBundle}
    static func run(output:URL,bundle:URL,directory:URL) async throws->Int32 {
        var checks:[[String:Any]]=[],trace:[[String:Any]]=[]
        func check(_ name:String,_ passed:Bool){checks.append(["name":name,"passed":passed]);if !passed{print("FAIL: "+name)}}
        let executable=GuardianExecutable.url(in:bundle)
        check("native service resolves the packaged guardian at the production relative path",FileManager.default.isExecutableFile(atPath:executable.path))
        let helperBundle=executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let info=Bundle(url:helperBundle)
        check("packaged guardian selects the real native entry",info?.object(forInfoDictionaryKey:"CUANativeGuardianHelper") as? Bool==true)
        var pid:Int32=0,connection:GuardianNativeConnection?,port:GuardianNativeRendezvous?,errorText:String?
        var terminal=false,cleanupRequired=false,endpointReceived=false,channelIdentified=false
        var auditedSender:Int32=0,opaquePeerPID:Int32=0
        func alive(_ pid:Int32)->Bool {pid>0 && (kill(pid,0)==0 || errno != ESRCH)}
        func startup(_ arguments:[String],name:String) async throws {
            let process=Process();process.executableURL=executable;process.arguments=arguments
            let stderr=directory.appendingPathComponent(name+"-stderr.log")
            _ = FileManager.default.createFile(atPath:stderr.path,contents:Data())
            let sink=try FileHandle(forWritingTo:stderr);defer{try? sink.close()}
            process.standardOutput=sink;process.standardError=sink
            try process.run()
            for _ in 0..<200 where process.isRunning {try await Task.sleep(for:.milliseconds(10))}
            if process.isRunning {process.terminate();process.waitUntilExit()}
            trace.append(["startup":name,"arguments":arguments,"pid":process.processIdentifier,"status":process.terminationStatus,"terminationReason":process.terminationReason.rawValue])
            if name=="empty-rendezvous" {
                check("empty rendezvous keeps the fatal foreign startup exception",process.terminationReason == .uncaughtSignal && process.terminationStatus==SIGTRAP)
            } else {check(name+" terminates through native application lifecycle",process.terminationReason == .exit && process.terminationStatus==0)}
        }
        do {
            try await startup([],name:"missing-rendezvous")
            try await startup([""],name:"empty-rendezvous")
            try await startup(["owned.cua.C161.absent."+UUID().uuidString,"ignored-extra"],name:"unregistered-rendezvous-with-extra-argument")
            guard let host=Bundle(url:bundle) else{throw Failure.invalidBundle}
            let environment=GuardianNativeEnvironment(bundle:host,prefix:"owned.cua.C161.idle.")
            let name=environment.rendezvousName(),registered=try environment.register(name:name);port=registered
            check("actual native Mach rendezvous owns a live receive port",registered.receivePort != 0)
            pid=try environment.launch(name:name)
            try JSONSerialization.data(withJSONObject:["pid":pid,"executable":executable.path]).write(to:directory.appendingPathComponent("guardian-child-pid.json"))
            check("actual production launcher starts a distinct packaged native helper",pid>0 && pid != getpid())
            let receivePort=registered.receivePort
            let (endpoint,sender)=try await Task.detached(operation:{try Self.auditedEndpoint(receivePort)}).value
            auditedSender=sender
            endpointReceived=true
            check("packaged native helper sends its actual anonymous XPC endpoint",endpointReceived)
            let callbacks=OSAllocatedUnfairLock(initialState:0),errors=OSAllocatedUnfairLock(initialState:[String]())
            let receiver=ExternalGuardianCallbackReceiver{callbacks.withLock{$0 += 1}}
            let first=environment.connection(endpoint:endpoint,receiver:receiver);connection=first
            first.setHandlers(invalidation:{},interruption:{})
            first.activate()
            let thread="owned-C161-idle-no-lease-"+UUID().uuidString
            let sent=first.sendLease(threadID:thread,retain:false,remoteError:{error in errors.withLock{$0.append(String(reflecting:error))}})
            trace.append(["method":"releaseAutoUnlockedLeaseForThreadID:","thread":thread,"sent":sent])
            try await Task.sleep(for:.milliseconds(100))
            opaquePeerPID=first.value.processIdentifier
            channelIdentified=sent && auditedSender==pid
            check("kernel endpoint audit metadata identifies the actual packaged helper PID",channelIdentified)
            check("unknown idle lease release reports no native transport error",errors.withLock{$0.isEmpty})
            let windowInfo=CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]]
            let visible=(windowInfo ?? []).filter{($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value==pid}
            check("idle native helper creates no on-screen protection window",windowInfo != nil && visible.isEmpty)
            let secondErrors=OSAllocatedUnfairLock(initialState:[String]())
            let second=environment.connection(endpoint:endpoint,receiver:receiver)
            second.setHandlers(invalidation:{secondErrors.withLock{$0.append("invalidated")}},interruption:{secondErrors.withLock{$0.append("interrupted")}})
            second.activate()
            _=second.sendLease(threadID:thread,retain:false,remoteError:{error in secondErrors.withLock{$0.append(String(reflecting:error))}})
            trace.append(["method":"releaseAutoUnlockedLeaseForThreadID:","connection":"second","thread":thread])
            for _ in 0..<150 where secondErrors.withLock({$0.isEmpty}) {try await Task.sleep(for:.milliseconds(10))}
            check("actual native guardian rejects a second simultaneous host channel",secondErrors.withLock{!$0.isEmpty})
            second.value.invalidate()
            check("rejected second channel leaves first native helper idle and alive",alive(pid) && errors.withLock{$0.isEmpty})
            check("idle native helper emits no physical-input callback",callbacks.withLock{$0==0})
            first.value.invalidate();connection=nil
            registered.invalidate();port=nil
            for _ in 0..<250 where alive(pid){try await Task.sleep(for:.milliseconds(10))}
            terminal = !alive(pid)
            check("native idle connection invalidation terminates packaged helper",terminal)
        }catch{
            errorText=String(reflecting:error);check("native packaged helper checks complete without error",false)
        }
        connection?.value.invalidate();port?.invalidate()
        if pid>0 && alive(pid) {
            var bytes=[CChar](repeating:0,count:4096)
            let count=bytes.withUnsafeMutableBytes{proc_pidpath(pid,$0.baseAddress,UInt32($0.count))}
            let path=String(decoding:bytes.prefix{ $0 != 0 }.map{UInt8(bitPattern:$0)},as:UTF8.self)
            guard count>0,URL(fileURLWithPath:path).resolvingSymlinksInPath()==executable.resolvingSymlinksInPath() else{throw Failure.invalidBundle}
            cleanupRequired=true;kill(pid,SIGTERM)
            for _ in 0..<100 where alive(pid){try? await Task.sleep(for:.milliseconds(10))}
        }
        if pid>0 {terminal = !alive(pid)}
        let passed=checks.allSatisfy{$0["passed"] as? Bool==true} && terminal
        let report:[String:Any]=["checks":checks,"passed":passed,"trace":trace,"error":errorText as Any? ?? NSNull(),
            "helperPID":pid,"kernelEndpointSenderPID":auditedSender,"oneWayNSXPCPeerPIDObserved":opaquePeerPID,"helperTerminal":terminal,"cleanupRequired":cleanupRequired,
            "actualPackagedNativeHelperLaunched":pid>0,"actualNativeMachAndXPCTransport":endpointReceived && channelIdentified,
            "protectionOrGuardStarted":false,"leaseAcquired":false,"physicalInputFocusCaptureOrSystemPointerMovement":false,
            "nativeProtectionProvidersIntercepted":false,"diagnosticKernelEndpointAuditReceiverUsed":true,"fullGoalComplete":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Packaged native guardian: \(checks.filter{$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
}
