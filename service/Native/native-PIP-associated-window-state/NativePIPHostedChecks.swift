import AppKit
import Darwin
import AVFoundation
import Foundation
import XPC
import os

@objc(OwnedC159HostedPIPBootstrap) protocol HostedBootstrapProtocol {
    func endpoint(reply:@escaping(NSXPCListenerEndpoint,Int32)->Void)
    func startWindow(_ id:UInt32,reply:@escaping(String,NSError?)->Void)
    func associated(_ ids:[NSNumber],reply:@escaping(Data)->Void)
    func snapshot(reply:@escaping(Data)->Void)
    func showCursor(reply:@escaping()->Void)
    func shutdown(reply:@escaping()->Void)
}

@MainActor private final class HostedBootstrap:NSObject,HostedBootstrapProtocol {
    let publisher=RemoteHostedPIPContentPublisher()
    var stream:RemoteHostedPIPContentStream?
    weak var renderer:RemoteHostedPIPWindowRenderer?
    var cursor:CursorOverlay?
    var windowID:UInt32=0,frames=0,cursorFrames=0,coloredCursorFrames=0,cursorRefreshActive=0,geometryUpdatesFinished=0
    nonisolated func endpoint(reply:@escaping(NSXPCListenerEndpoint,Int32)->Void) {
        Task { @MainActor in reply(self.publisher.endpointForHostConnection(),getpid()) }
    }
    nonisolated func startWindow(_ id:UInt32,reply:@escaping(String,NSError?)->Void) {
        Task { @MainActor [self] in
            guard CGPreflightScreenCaptureAccess() else {
                reply("",NSError(domain:"OwnedC159NativeHost",code:1,userInfo:[NSLocalizedDescriptionKey:"Screen capture permission is unavailable in the owned XPC service"]));return
            }
            self.windowID=id
            let stream=RemoteHostedPIPContentStream(publisher:self.publisher,threadID:"owned-C159-host",turnID:"native") { [weak self] publishFrame in
                let renderer=RemoteHostedPIPWindowRenderer(windowID:id,associatedWindowIDs:[],onCursorFrame:{ [weak self] image in
                    self?.cursorFrames += 1
                    if NativePIPHostedChecks.containsVisiblePixels(image) {self?.coloredCursorFrames += 1}
                }) { [weak self] image in self?.frames += 1;publishFrame(image) }
                renderer.diagnosticEventHandler={ [weak self] event in
                    if event=="cursor-refresh:begin"{self?.cursorRefreshActive += 1}
                    if event=="cursor-refresh:end"{self?.cursorRefreshActive -= 1}
                    if event=="geometry-update:end"{self?.geometryUpdatesFinished += 1}
                }
                self?.renderer=renderer
                return renderer
            }
            self.stream=stream;self.publisher.registerExistingStream(stream);reply(stream.presentationID,nil)
        }
    }
    nonisolated func associated(_ ids:[NSNumber],reply:@escaping(Data)->Void) {
        Task { @MainActor in
            self.stream?.setAssociatedWindowIDs(ids.map(\.uint32Value))
            let value:[String:Any]=["stored":self.stream?.diagnosticAssociatedWindowIDs ?? [],
                "renderer":self.renderer?.diagnosticAssociatedWindowIDs ?? [],
                "geometryGeneration":String(self.renderer?.diagnosticState.geometryGeneration ?? -1),
                "captureGeneration":String(self.renderer?.diagnosticState.captureGeneration ?? -1),
                "finished":self.geometryUpdatesFinished]
            reply(try! JSONSerialization.data(withJSONObject:value))
        }
    }
    nonisolated func snapshot(reply:@escaping(Data)->Void) {
        Task { @MainActor in
            var value=self.stream?.diagnosticHostTransactionState ?? [:]
            value["pid"]=getpid();value["frames"]=self.frames;value["cursorFrames"]=self.cursorFrames;value["coloredCursorFrames"]=self.coloredCursorFrames
            value["associatedWindowIDs"]=self.stream?.diagnosticAssociatedWindowIDs ?? []
            value["rendererAssociatedWindowIDs"]=self.renderer?.diagnosticAssociatedWindowIDs ?? []
            value["geometryUpdatesFinished"]=self.geometryUpdatesFinished
            value["cursorRefreshActive"]=self.cursorRefreshActive
            value["connected"]=self.publisher.transport.connection != nil
            value["peerPID"]=self.publisher.transport.connection?.processIdentifier ?? -1
            value["diagnosticErrors"]=self.publisher.connectionDiagnostics.events.compactMap{$0.error?.message}
            value["cursorWindowID"]=self.cursor?.currentVisibleWindowID() as Any? ?? NSNull()
            if let state=self.renderer?.diagnosticState {
                value["geometryGeneration"]=String(state.geometryGeneration);value["captureGeneration"]=String(state.captureGeneration)
                value["captureWindowIDs"]=state.captureKey?.windowIDs ?? [];value["displayCapture"]=state.captureKey?.displayID != nil
                value["geometryObserver"]=state.hasGeometryObserver;value["cursorObserver"]=state.hasCursorObserver
                value["hasCursorCapture"]=state.hasCursorCapture;value["cursorHidden"]=state.cursorHidden
                value["suspended"]=state.frameDeliverySuspended;value["sourceUnavailable"]=state.sourceUnavailable
                value["cursorTargetBounds"]=state.cursorLayerGeometry.map{[Double($0.targetBounds.minX),Double($0.targetBounds.minY),Double($0.targetBounds.width),Double($0.targetBounds.height)]} as Any? ?? NSNull()
                value["bounds"]=state.targetBounds.map{[Double($0.minX),Double($0.minY),Double($0.width),Double($0.height)]} as Any? ?? NSNull()
            }
            reply((try? JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])) ?? Data())
        }
    }
    nonisolated func showCursor(reply:@escaping()->Void) {
        Task { @MainActor in
            if let bounds=self.renderer?.diagnosticState.targetBounds {
                let cursor=self.cursor ?? CursorOverlay();self.cursor=cursor
                cursor.place(at:.init(x:bounds.minX+min(70,bounds.width/2),y:bounds.minY+min(70,bounds.height/2)),animated:false,targetWindowID:self.windowID)
            }
            reply()
        }
    }
    nonisolated func shutdown(reply:@escaping()->Void) {
        Task { @MainActor in
            self.cursor?.hide();self.cursor=nil
            self.publisher.resetRemoteHostedStreams()
            reply()
            DispatchQueue.global().asyncAfter(deadline:.now()+0.2){exit(0)}
        }
    }
}
private final class HostedBootstrapListener:NSObject,NSXPCListenerDelegate {
    let object:HostedBootstrap
    var connections:[NSXPCConnection]=[]
    init(_ object:HostedBootstrap){self.object=object}
    func listener(_ listener:NSXPCListener,shouldAcceptNewConnection connection:NSXPCConnection)->Bool {
        connection.exportedInterface=NSXPCInterface(with:HostedBootstrapProtocol.self);connection.exportedObject=object
        connections.append(connection);connection.activate();return true
    }
}
private final class HostedPeer:NSObject,RemoteHostedPIPContentHostXPCProtocol,@unchecked Sendable {
    private let lock=NSLock()
    private var stored:[[String:Any]]=[]
    var rows:[[String:Any]] {lock.lock();defer{lock.unlock()};return stored}
    private func record(_ value:[String:Any]){lock.lock();stored.append(value);lock.unlock()}
    func publishPresentation(id:String,threadID:String,turnID:String,contextID:UInt32,width:Double,height:Double,reply:@escaping RemoteHostedPIPReply) {
        record(["method":"publish","id":id,"thread":threadID,"turn":turnID,"context":contextID,"width":width,"height":height]);reply(nil)
    }
    func setSourceProcessIdentifier(_ pid:Int32,presentationID:String,reply:@escaping RemoteHostedPIPReply){record(["method":"pid","id":presentationID,"pid":pid]);reply(nil)}
    func prepareOperation(presentationID:String,operationID:UInt64,kind:String,contextID:UInt32,width:Double,height:Double,fencePayload:RemoteHostedPIPFencePayload,reply:@escaping RemoteHostedPIPReply) {
        let port=xpc_dictionary_copy_mach_send(fencePayload,"fence")
        var type:mach_port_type_t=0,refs:mach_port_urefs_t=0
        let typeResult=mach_port_type(mach_task_self_,port,&type)
        let refsResult=mach_port_get_refs(mach_task_self_,port,mach_port_right_t(MACH_PORT_RIGHT_SEND),&refs)
        let valid=port != 0 && typeResult==KERN_SUCCESS && refsResult==KERN_SUCCESS && type & (UInt32(1) << (UInt32(MACH_PORT_RIGHT_SEND)+16)) != 0 && refs>0
        if port != 0 {mach_port_deallocate(mach_task_self_,port)}
        record(["method":"prepare","id":presentationID,"operation":String(operationID),"kind":kind,"context":contextID,
            "width":width,"height":height,"validSendRight":valid,"fenceEntries":Int(xpc_dictionary_get_count(fencePayload))]);reply(nil)
    }
    func completeOperation(presentationID:String,operationID:UInt64,reply:@escaping RemoteHostedPIPReply){record(["method":"complete","id":presentationID,"operation":String(operationID)]);reply(nil)}
    func willEndStream(presentationID:String,reply:@escaping RemoteHostedPIPReply){record(["method":"willEnd","id":presentationID]);reply(nil)}
    func invalidatePresentation(id:String,reply:@escaping RemoteHostedPIPReply){record(["method":"invalidate","id":id]);reply(nil)}
    func publishFrame(presentationID:String,videoData:Data,decoderConfiguration:Data?,codec:String,timestamp:UInt64,isKeyFrame:Bool,reply:@escaping RemoteHostedPIPReply){reply(nil)}
    func noteInteraction(presentationID:String,reply:@escaping RemoteHostedPIPReply){reply(nil)}
    func setComputerUseCursorLocation(x:Double,y:Double,isActive:Bool,reply:@escaping RemoteHostedPIPReply){reply(nil)}
}

@MainActor enum NativePIPHostedChecks {
    private enum Failure:Error {case unavailable(String),timeout(String),invalidJSON}
    static func runOwnedService()->Never {
        let directory=URL(fileURLWithPath:Bundle.main.object(forInfoDictionaryKey:"C160SessionDirectory") as! String,isDirectory:true)
        try! JSONSerialization.data(withJSONObject:["pid":getpid(),"executable":Bundle.main.executableURL!.path]).write(to:directory.appendingPathComponent("hosted-child-pid.json"))
        let app=NSApplication.shared;_ = app.setActivationPolicy(.prohibited)
        let object=HostedBootstrap(),delegate=HostedBootstrapListener(object),listener=NSXPCListener.service()
        listener.delegate=delegate
        return withExtendedLifetime((object,delegate,listener)){listener.resume();app.run();exit(4)}
    }
    static func containsVisiblePixels(_ image:CVPixelBuffer)->Bool {
        guard CVPixelBufferGetPixelFormatType(image)==kCVPixelFormatType_32BGRA,CVPixelBufferLockBaseAddress(image,.readOnly)==kCVReturnSuccess else{return false}
        defer{CVPixelBufferUnlockBaseAddress(image,.readOnly)}
        guard let base=CVPixelBufferGetBaseAddress(image) else{return false}
        let bytes=base.assumingMemoryBound(to:UInt8.self),stride=CVPixelBufferGetBytesPerRow(image)
        for y in 0..<CVPixelBufferGetHeight(image){for x in 0..<CVPixelBufferGetWidth(image){let p=y*stride+x*4;if bytes[p+3]>16 && max(bytes[p],bytes[p+1],bytes[p+2])>24{return true}}}
        return false
    }
    private static func request<T>(_ broker:NSXPCConnection,send:(HostedBootstrapProtocol,@escaping(Result<T,any Error>)->Void)->Void) async throws ->T {
        try await withCheckedThrowingContinuation { continuation in
            let pending=OSAllocatedUnfairLock(initialState:Optional(continuation))
            let finish:(Result<T,any Error>)->Void={ result in
                let current=pending.withLock {value in let old=value;value=nil;return old};current?.resume(with:result)
            }
            guard let proxy=broker.remoteObjectProxyWithErrorHandler({finish(.failure($0))}) as? HostedBootstrapProtocol else {finish(.failure(Failure.unavailable("bootstrap")));return}
            send(proxy,finish)
        }
    }
    private static func connect(_ connection:NSXPCConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,any Error>) in
            let pending=OSAllocatedUnfairLock(initialState:Optional(continuation))
            let finish:RemoteHostedPIPReply={ error in
                let current=pending.withLock {value in let old=value;value=nil;return old}
                if let error {current?.resume(throwing:error)} else {current?.resume()}
            }
            guard let producer=connection.remoteObjectProxyWithErrorHandler({finish($0 as NSError)}) as? RemoteHostedPIPContentProducerXPCProtocol else {
                finish(NSError(domain:"OwnedC159NativeHost",code:2));return
            }
            producer.connect(reply:finish)
        }
    }
    @MainActor final class Session {
        private let broker:NSXPCConnection
        private let peer=HostedPeer()
        private var connection:NSXPCConnection?
        private let directory:URL
        private(set) var checks:[[String:Any]]=[]
        private(set) var latest:[String:Any]=[:]
        private(set) var childPID:Int32=0
        private(set) var childTerminal=false
        private var presentationID=""
        private var framesBeforeResize=0
        init(directory:URL) throws {
            guard let id=Bundle.main.bundleIdentifier else{throw Failure.unavailable("owned host bundle")}
            self.directory=directory
            broker=NSXPCConnection(serviceName:id+".child");broker.remoteObjectInterface=NSXPCInterface(with:HostedBootstrapProtocol.self);broker.activate()
        }
        private func check(_ name:String,_ passed:Bool){checks.append(["name":name,"passed":passed]);if !passed{print("FAIL: "+name)}}
        func start(windowID:UInt32,targetPID:Int32) async throws {
            let (endpoint,pid):(NSXPCListenerEndpoint,Int32)=try await request(broker){proxy,done in proxy.endpoint{done(.success(($0,$1)))}}
            childPID=pid;check("hosted publisher runs in a distinct owned native service process",pid>0 && pid != getpid())
            let connection=NSXPCConnection(listenerEndpoint:endpoint)
            connection.exportedInterface=RemoteHostedPIPXPC.hostInterface();connection.exportedObject=peer
            connection.remoteObjectInterface=RemoteHostedPIPXPC.producerInterface();connection.activate();self.connection=connection
            try await NativePIPHostedChecks.connect(connection)
            latest=try await wait("native host connection adoption"){$0["connected"] as? Bool==true && $0["peerPID"] as? Int32==getpid()}
            check("native producer handshake adopts the actual host process",latest["connected"] as? Bool==true && latest["peerPID"] as? Int32==getpid())
            presentationID=try await request(broker){proxy,done in proxy.startWindow(windowID){id,error in if let error {done(.failure(error))}else{done(.success(id))}}}
            latest=try await wait("native window publication") {($0["published"] as? Bool)==true && ($0["frames"] as? Int ?? 0)>0}
            let publications=peer.rows.filter{$0["method"] as? String=="publish"}
            check("actual hosted native window publishes its real CAContext",publications.count==1 && (publications[0]["context"] as? UInt32 ?? 0)>0 && publications[0]["id"] as? String==presentationID)
            check("actual hosted prepare retains geometry and finish observers",latest["geometryObserver"] as? Bool==true && latest["cursorObserver"] as? Bool==true)
            check("actual hosted window streams native frames without suspended delivery",latest["suspended"] as? Bool==false && (latest["frames"] as? Int ?? 0)>0)
            _=try await wait("source PID publication"){_ in self.peer.rows.contains{$0["method"] as? String=="pid" && $0["pid"] as? Int32==targetPID}}
            check("source process publication names the owned form",peer.rows.contains{$0["method"] as? String=="pid" && $0["pid"] as? Int32==targetPID})
            let _:Void=try await request(broker){proxy,done in proxy.showCursor{done(.success(()))}}
            latest=try await wait("finish notification creates visible native cursor capture"){($0["hasCursorCapture"] as? Bool)==true && ($0["coloredCursorFrames"] as? Int ?? 0)>0}
            check("actual finish notification routes to native cursor capture without manual refresh",latest["hasCursorCapture"] as? Bool==true && (latest["coloredCursorFrames"] as? Int ?? 0)>0)
            framesBeforeResize=latest["frames"] as? Int ?? 0
        }
        func resize() async throws {
            try "resize-host".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
            latest=try await wait("progress and settled native host resize") {
                $0["nextOperation"] as? String=="3" && $0["layoutGeneration"] as? String=="1" && $0["suspended"] as? Bool==false && ($0["frames"] as? Int ?? 0)>self.framesBeforeResize
            }
            latest=try await wait("settled native cursor geometry before source close") {
                ($0["cursorRefreshActive"] as? Int)==0 && ($0["hasCursorCapture"] as? Bool)==true &&
                $0["cursorTargetBounds"] as? [Double] == $0["bounds"] as? [Double]
            }
            check("hosted cursor finishes geometry refresh before settled source-loss scenario",latest["cursorRefreshActive"] as? Int==0 && latest["cursorTargetBounds"] as? [Double]==latest["bounds"] as? [Double])
            let operations=peer.rows.filter{["prepare","complete"].contains($0["method"] as? String ?? "")}
            check("real geometry delivers separate progress and settled host operations",operations.count==4 && operations.map{$0["method"] as? String ?? ""}==["prepare","complete","prepare","complete"])
            let prepare=operations.filter{$0["method"] as? String=="prepare"}
            check("native host receives exact progress then resize kinds",prepare.map{$0["kind"] as? String ?? ""}==["resize-in-progress","resize"])
            check("native host pairs each operation with its matching completion",operations.map{$0["operation"] as? String ?? ""}==["1","1","2","2"])
            check("actual graphical fence payloads contain live Mach send rights",prepare.count==2 && prepare.allSatisfy{$0["validSendRight"] as? Bool==true && $0["fenceEntries"] as? Int==1})
            let context=peer.rows.first{$0["method"] as? String=="publish"}?["context"] as? UInt32
            check("native resize retains the published graphical context",context != nil && prepare.allSatisfy{$0["context"] as? UInt32==context})
            check("host completion advances counters and resumes native image delivery",latest["nextOperation"] as? String=="3" && latest["layoutGeneration"] as? String=="1" && latest["suspended"] as? Bool==false)
            check("actual hosted root size matches settled presentation size",latest["rootSize"] as? [Double]==latest["size"] as? [Double])
            check("hosted native transitions report no transport errors",(latest["diagnosticErrors"] as? [String])?.isEmpty==true)
        }
        private func associated(_ ids:[UInt32]) async throws->[String:Any] {
            let data:Data=try await request(broker){proxy,done in proxy.associated(ids.map{NSNumber(value:$0)}){done(.success($0))}}
            guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw Failure.invalidJSON};return value
        }
        func associationUpdates(windowID:UInt32) async throws {
            let generation=Int(latest["geometryGeneration"] as! String)!
            let duplicate=try await associated([windowID,windowID])
            check("associated arrays commit duplicate IDs synchronously to actual stream and renderer",duplicate["stored"] as? [UInt32]==[windowID,windowID] && duplicate["renderer"] as? [UInt32]==[windowID,windowID] && duplicate["geometryGeneration"] as? String==String(generation+1))
            latest=try await wait("associated display capture settles") {
                $0["captureWindowIDs"] as? [UInt32]==[windowID,windowID] && $0["displayCapture"] as? Bool==true && $0["nextOperation"] as? String=="5" && $0["layoutGeneration"] as? String=="2" && $0["cursorRefreshActive"] as? Int==0 && $0["cursorTargetBounds"] as? [Double]==$0["bounds"] as? [Double]
            }
            check("associated source change uses native debounce then separate progress and settled host operations",latest["nextOperation"] as? String=="5" && latest["layoutGeneration"] as? String=="2")
            let captureGeneration=latest["captureGeneration"] as! String
            let stable=try await associated([windowID,windowID])
            check("identical associated array neither advances geometry nor schedules another update",stable["geometryGeneration"] as? String==latest["geometryGeneration"] as? String && stable["finished"] as? Int==latest["geometryUpdatesFinished"] as? Int)
            let finished=stable["finished"] as! Int
            let first=try await associated([windowID,0])
            let second=try await associated([0,windowID])
            let last=try await associated([windowID])
            check("rapid native associated updates preserve each supplied order before coalescing",first["stored"] as? [UInt32]==[windowID,0] && second["stored"] as? [UInt32]==[0,windowID] && last["stored"] as? [UInt32]==[windowID] && Int(last["geometryGeneration"] as! String)==Int(stable["geometryGeneration"] as! String)!+3)
            latest=try await wait("coalesced equal capture key"){$0["geometryUpdatesFinished"] as? Int==finished+1}
            check("changed associated array with equal capture key retains native stream and host counters",latest["captureGeneration"] as? String==captureGeneration && latest["nextOperation"] as? String=="5" && latest["associatedWindowIDs"] as? [UInt32]==[windowID])
            _=try await associated([])
            latest=try await wait("associated clear restores independent source") {
                $0["captureWindowIDs"] as? [UInt32]==[windowID] && $0["displayCapture"] as? Bool==false && $0["nextOperation"] as? String=="7" && $0["layoutGeneration"] as? String=="3" && $0["cursorRefreshActive"] as? Int==0 && $0["cursorTargetBounds"] as? [Double]==$0["bounds"] as? [Double]
            }
            check("clearing associations restores independent native capture and resumes delivery",latest["suspended"] as? Bool==false && latest["rendererAssociatedWindowIDs"] as? [UInt32]==[])
            let operations=peer.rows.filter{["prepare","complete"].contains($0["method"] as? String ?? "")}
            check("associated transitions retain exact additional host operation and fence ordering",operations.count==12 && operations.map{$0["operation"] as? String ?? ""}==["1","1","2","2","3","3","4","4","5","5","6","6"] && operations.filter{$0["method"] as? String=="prepare"}.allSatisfy{$0["validSendRight"] as? Bool==true})
        }
        func sourceClosed() async throws {
            latest=try await wait("native hosted source loss") {($0["sourceUnavailable"] as? Bool)==true && self.peer.rows.contains{$0["method"] as? String=="willEnd"}}
            check("actual hosted source destruction ends stream through native host",latest["invalidated"] as? Bool==true && peer.rows.filter{$0["method"] as? String=="willEnd"}.count==1)
            check("actual hosted source loss hides and detaches cursor capture",latest["hasCursorCapture"] as? Bool==false && latest["cursorHidden"] as? Bool==true && latest["suspended"] as? Bool==true)
            let afterLoss=try await associated([0,0])
            check("invalidated native stream still stores and forwards associated array",afterLoss["stored"] as? [UInt32]==[0,0] && afterLoss["renderer"] as? [UInt32]==[0,0])
        }
        private func snapshot() async throws ->[String:Any] {
            let data:Data=try await request(broker){proxy,done in proxy.snapshot{done(.success($0))}}
            guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any] else{throw Failure.invalidJSON};return value
        }
        private func wait(_ label:String,condition:([String:Any])->Bool) async throws ->[String:Any] {
            for _ in 0..<300 {
                let state=try await snapshot()
                latest=state
                if condition(state){return state}
                try await Task.sleep(for:.milliseconds(10))
            }
            throw Failure.timeout(label)
        }
        func stop() async {
            guard !childTerminal else {return}
            let _:Void?=try? await request(broker){proxy,done in proxy.shutdown{done(.success(()))}}
            connection?.invalidate();connection=nil;broker.invalidate()
            for _ in 0..<100 {
                if childPID>0,kill(childPID,0) != 0,errno==ESRCH {childTerminal=true;break}
                try? await Task.sleep(for:.milliseconds(10))
            }
            check("owned native hosted service terminates",childTerminal)
        }
        var report:[String:Any] { ["checks":checks,"passed":checks.allSatisfy{$0["passed"] as? Bool==true},"peerRows":peer.rows,
            "lastState":latest,"childPID":childPID,"childTerminal":childTerminal,"actualNativeWindowAndHostXPC":peer.rows.contains{$0["method"] as? String=="publish"} && (latest["frames"] as? Int ?? 0)>0,"captureAXFenceAndTransportProvidersIntercepted":false,
            "actualPhysicalInputFocusOrSystemPointerMovement":false] }
    }
}
