import AppKit
import ApplicationServices
import Foundation

enum ControllerGlobalFocusNative {
    typealias Event = ControllerFocusNativeEvent
    typealias Node = ControllerNativeElementContext.Node
    typealias Resolver = ControllerGlobalFocusResolver<Node>
    typealias Manager = ControllerGlobalFocusManager<Event>
    private static let focusSPI=ControllerGlobalFocusSPI.resolve()

    static func bridgePID() -> Int32? {
        // Fresh user-only SAIRunningProcess filter, first result,
        // no cached bridge PID or alternate process-name match.
        RunningProcessSearch.find(.init(name:"ViewBridgeAuxiliary",options:1))?.first?.pid
    }
    static func element(_ name:String, _ node:Node, context:ControllerNativeElementContext) -> Node? {
        if let cached=node.snapshot.values[name], let element=try? ControllerNativeElementDecoding.element(cached,strict:false) {
            return context.context.node(element)
        }
        guard EventStreamAttributeAvailability.mayRead(name,supported:node.snapshot.supported,requested:node.snapshot.requested) else { return nil }
        do {
            guard let value=try context.context.environment.read(node.element,name),
                  let element=try ControllerNativeElementDecoding.element(value,strict:true) else { return nil }
            return context.context.node(element)
        } catch { context.log(name,error); return nil }
    }
    static func resolver(context:ControllerNativeElementContext,
        ordinaryPID:@escaping @Sendable (SettingsNativeAXElement) -> Int32?,
        synthesizedActions:ControllerFocusSynthesizedActionState = .shared) -> Resolver {
        .init(environment:.init(query:{
            focusSPI?.observe()
        },bridgePID:{bridgePID()},policy:{NSRunningApplication(processIdentifier:$0)?.activationPolicy.rawValue},
            frontmostPID:{NSWorkspace.shared.frontmostApplication?.processIdentifier},application:{context.application($0)},
            focused:{element("AXFocusedUIElement",$0,context:context)},
            focusedWindow:{context.context.focusedWindow($0)},mainWindow:{context.context.mainWindow($0)},
            ordinaryPID:{try ControllerAXEnablementNative.pid($0.element,lookup:ordinaryPID)},
            actualPID:{try context.identity.actualPID($0.element)},nameHostPID:{pid in
                guard let app=NSRunningApplication(processIdentifier:pid),let name=app.localizedName,
                      let expected=Resolver.hostName(name) else {return nil}
                let matches=NSWorkspace.shared.runningApplications.filter {$0.localizedName == expected && $0.activationPolicy != .prohibited}
                return matches.count == 1 ? matches[0].processIdentifier : nil
            },synthesizedAction:{synthesizedActions.value},uptime:{ProcessInfo.processInfo.systemUptime},
            sleepMicroseconds:{_ = usleep($0)}))
    }
    static func registry(context:ControllerNativeElementContext,
        ordinaryPID:@escaping @Sendable (SettingsNativeAXElement) -> Int32?,
        synthesizedActions:ControllerFocusSynthesizedActionState = .shared) -> ControllerGlobalFocusRegistry<Event> {
        let resolver=resolver(context:context,ordinaryPID:ordinaryPID,synthesizedActions:synthesizedActions)
        return .init(environment:.init(makeTap:{ControllerFocusNativeTap($0)},currentFocus:{resolver.current()},
            bridgePID:{bridgePID()},resolve:{resolver.resolve($0)},processIdentifier:{getpid()},
            integer:{$0.event.getIntegerValueField(CGEventField(rawValue:$1)!)},noticeField:64,noticePIDField:73,
            releaseTokenField:71,windowField:51,windowOwner:{ControllerWindowDescription.lookup($0)?.ownerPID},
            post:{$0.event.postToPid($1)},enqueueCallback:{callback in Task {callback()}},
            previousFocusedProcess:{pid in
                let focused=element("AXFocusedUIElement",context.application(pid),context:context)
                for node in AXParentChain(start:focused,maximumDepth:300,includingSelf:true,
                    parent:{element("AXParent",$0,context:context)}) {
                    if let owner=try? context.identity.actualPID(node.element),
                       let app=NSRunningApplication(processIdentifier:owner),app.isFinishedLaunching {
                        return app.activationPolicy == .prohibited ? .service : .application
                    }
                }
                return nil
            },releaseFocus:{focusSPI?.release?($0) == 0},repairHost:{pid in
                _ = Task.detached { try repair(pid:pid) }
            }))
    }
    static func repairEvent(_ subtype:UInt16) throws -> Event {
        guard let type=NSEvent.EventType(rawValue:21),let event=NSEvent.otherEvent(with:type,location:.zero,
            modifierFlags:[],timestamp:0,windowNumber:0,context:nil,subtype:Int16(bitPattern:subtype),data1:0,data2:0)?.cgEvent else {
            throw ControllerFocusNativeEvents.Failure.cannotCreateEvent
        }
        return .init(event:event)
    }
    static func repair(pid:Int32) throws {
        try ControllerGlobalFocusRepair.perform(pid:pid,make:{try repairEvent($0)},timestampAndPost:{event,pid in
            event.event.timestamp=DispatchTime.now().uptimeNanoseconds
            event.event.postToPid(pid)
        })
    }
}

extension ControllerGlobalFocusRegistry where Event == ControllerFocusNativeEvent {
    /// These are the C94 owner's real PID entry points, with no UUID lease,
    /// process-generation filtering or lifecycle guards added to queued work.
    var focusBindings:ControllerFocusPreventionBindings {
        .init(register:{self.start(pid:$0,lost:$1,gained:$2)},unregisterIfPresent:{self.stop(pid:$0)},
            currentlyFocused:{self.isFocused($0)},startMenuIfPresent:{self.startMenu(pid:$0,menuPID:$1)},
            stopMenuIfPresent:{self.stopMenu(pid:$0)})
    }
}
