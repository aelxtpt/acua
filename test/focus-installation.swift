import Foundation
import CoreGraphics

typealias JSON=[String:Any]
struct ServiceError:Error {enum Code {case permissionsNotGranted,accessibilityError};init(_ code:Code,_ message:String){}}

final class CFMachPort {let name:String;let callback:CGEventTapCallBack;let pointer:UnsafeMutableRawPointer?;init(_ name:String,_ callback:@escaping CGEventTapCallBack,_ pointer:UnsafeMutableRawPointer?){self.name=name;self.callback=callback;self.pointer=pointer}}
final class CFRunLoopSource {let port:CFMachPort;init(_ port:CFMachPort){self.port=port}}
enum RunLoopMode {case commonModes}
let kCFAllocatorDefault=0
func CFRunLoopGetMain()->Int{1}
func CFRunLoopAddSource(_ loop:Int,_ source:CFRunLoopSource,_ mode:RunLoopMode){Owned.trace.append("add:"+source.port.name)}
func CFRunLoopRemoveSource(_ loop:Int,_ source:CFRunLoopSource,_ mode:RunLoopMode){Owned.trace.append("remove:"+source.port.name)}
func CFMachPortCreateRunLoopSource(_ allocator:Int,_ port:CFMachPort,_ order:Int)->CFRunLoopSource?{Owned.trace.append("source:"+port.name);return Owned.noSource.contains(port.name) ? nil:CFRunLoopSource(port)}
func CFMachPortInvalidate(_ port:CFMachPort){Owned.trace.append("invalidate:"+port.name)}
typealias CGEventTapCallBack=(Int,CGEventType,CGEvent,UnsafeMutableRawPointer?)->Unmanaged<CGEvent>?
final class CGEvent {
    let subtype:Int64
    init(_ subtype:Int64=0){self.subtype=subtype}
    func getIntegerValueField(_ field:CGEventField)->Int64{subtype}
    static func tapCreateForPid(pid:Int32,place:CGEventTapPlacement,options:CGEventTapOptions,eventsOfInterest:CGEventMask,callback:@escaping CGEventTapCallBack,userInfo:UnsafeMutableRawPointer?)->CFMachPort?{
        let name=eventsOfInterest==(CGEventMask(1)<<13 | CGEventMask(1)<<19 | CGEventMask(1)<<20) ? "observer:\(pid)":"keyboard:\(pid)"
        return create(name,mask:eventsOfInterest,callback:callback,userInfo:userInfo)
    }
    static func tapCreate(tap:CGEventTapLocation,place:CGEventTapPlacement,options:CGEventTapOptions,eventsOfInterest:CGEventMask,callback:@escaping CGEventTapCallBack,userInfo:UnsafeMutableRawPointer?)->CFMachPort?{create("global",mask:eventsOfInterest,callback:callback,userInfo:userInfo)}
    static func create(_ name:String,mask:UInt64,callback:@escaping CGEventTapCallBack,userInfo:UnsafeMutableRawPointer?)->CFMachPort?{
        Owned.trace.append("create:"+name);Owned.masks[name]=mask
        if Owned.noPort.contains(name){return nil}
        let port=CFMachPort(name,callback,userInfo);Owned.ports[name]=port;return port
    }
    static func tapEnable(tap:CFMachPort,enable:Bool){Owned.trace.append("enable:\(tap.name):\(enable)")}
}
enum Owned {
    static var trace=[String](),ports=[String:CFMachPort](),masks=[String:UInt64](),noPort=Set<String>(),noSource=Set<String>()
    static var active=false,focusPID:Int32=0,bridge:Int32?=9,frontmost:Int32=0
    static func reset(){FocusStealPreventer.resetFixture();trace=[];ports=[:];masks=[:];noPort=[];noSource=[];active=false;focusPID=0;bridge=9;frontmost=0}
}
final class NSRunningApplication:NSObject {
    let processIdentifier:Int32
    var isActive:Bool{Owned.active};var isTerminated:Bool{false}
    init?(processIdentifier:Int32){self.processIdentifier=processIdentifier}
}
final class NSWorkspace {
    static let shared=NSWorkspace();let notificationCenter=NotificationCenter()
    static let didActivateApplicationNotification=Notification.Name("owned.activate"),didTerminateApplicationNotification=Notification.Name("owned.terminate"),applicationUserInfoKey="app"
    var frontmostApplication:NSRunningApplication?{NSRunningApplication(processIdentifier:Owned.frontmost)}
}
enum AppResolver {static func processKey(_ app:NSRunningApplication)->String{"p\(app.processIdentifier)"}}
enum KeyboardFocusResolver {static func current()->SystemKeyboardFocusState.Focus{.regularApp(Owned.focusPID)};static func viewBridgePID()->Int32?{Owned.bridge}}
final class FocusRestoration {func finish(){Owned.trace.append("restore-finish")}}
enum SyntheticFocusEvents {static func deactivation()throws->[CGEvent]{[CGEvent()]};static func send(_ events:[CGEvent],to pid:Int32){Owned.trace.append("deactivate:\(pid)")}}
/* STATE */
final class SyntheticFocusController {
    let pid:pid_t,processKey:String;private let lock=NSLock();private var state:SyntheticFocusState
    private var tap:CFMachPort?,source:CFRunLoopSource?,activationObserver:NSObjectProtocol?,terminationObserver:NSObjectProtocol?
    private var closed=false,restoration:FocusRestoration?,focusRegistration:UUID?
    /* CONTROLLER */
    var stateFixture:SyntheticFocusState{state}
}
final class FocusStealPreventer {
    private static let registryLock=NSLock();private static var shared:FocusStealPreventer?
    private let lock=NSLock();private var state:SystemKeyboardFocusState
    private var entries:[Entry]=[],global:Tap?,bridgeKeyboard:Tap?;private let bridgePID:Int32?;private let servicePID=getpid();private var closed=false
    private(set) var releaseAttempts=0,releaseSuccesses=0,suppressedEvents=0,redirectedKeys=0
    /* PREVENTER */
    private func filter(type:CGEventType,event:CGEvent,context:TapContext)->Unmanaged<CGEvent>?{Owned.trace.append("filter");return Unmanaged.passUnretained(event)}
    static func resetFixture(){shared?.finish();shared=nil}
}
@main struct InstallationTests {
    static func main()throws{
        var rows=[[String:Any]]()
        func check(_ ok:Bool,_ name:String){rows.append(["name":name,"passed":ok]);print("\(ok ? "PASS":"FAIL") focus installation \(name)")}
        let resources=["global","keyboard:9","keyboard:42","observer:42"]
        // For each observer independently: success, no port, or no source.
        for value in 0..<81 {
            Owned.reset();var encoded=value;var states=[Int]()
            for resource in resources {let state=encoded%3;encoded /= 3;states.append(state);if state==1{Owned.noPort.insert(resource)};if state==2{Owned.noSource.insert(resource)}}
            var controller:SyntheticFocusController?
            do{controller=try SyntheticFocusController(pid:42,processKey:"p42")}catch{}
            let installed=controller != nil && FocusStealPreventer.registrationCount==1 && !controller!.isClosed
            let allAttempted=resources.allSatisfy{Owned.trace.contains("create:"+$0)}
            let expectedPorts=states.filter{$0 != 1}.count
            let kept=Owned.trace.filter{$0.hasPrefix("invalidate:")}.isEmpty
            let keyboardReady=FocusStealPreventer.hasKeyboardFilter(for:42)==(states[2]==0)
            let initialState=controller?.stateFixture==SyntheticFocusState(believesActive:false,believesFocused:false,actuallyActive:false)
            controller?.close();controller?.close()
            let released=FocusStealPreventer.registrationCount==0 && Owned.trace.filter{$0.hasPrefix("invalidate:")}.count==expectedPorts && Set(Owned.trace.filter{$0.hasPrefix("invalidate:")}).count==expectedPorts
            check(installed && allAttempted && kept && keyboardReady && initialState && released,"independent installation matrix \(value) \(states)")
        }
        if CommandLine.arguments.contains("--matrix-only") {
            let passed=rows.filter{$0["passed"] as? Bool==true}.count
            try JSONSerialization.data(withJSONObject:["passed":passed,"failed":rows.count-passed,"checks":rows,"installation_matrix_cases":81],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
            if passed != rows.count && !CommandLine.arguments.contains("--observe"){exit(1)}
            return
        }
        Owned.reset();Owned.noPort=["global","keyboard:9","keyboard:42"]
        let one=try FocusStealPreventer.register(pid:42,processKey:"p42",lost:{},gained:{})
        let two=try FocusStealPreventer.register(pid:43,processKey:"p43",lost:{},gained:{})
        check(FocusStealPreventer.registrationCount==2 && FocusStealPreventer.hasKeyboardFilter(for:43) && Owned.trace.filter{$0=="create:global"}.count==1,"later registration survives earlier failed filters without global retry")
        FocusStealPreventer.unregister(one)
        check(FocusStealPreventer.registrationCount==1 && FocusStealPreventer.hasKeyboardFilter(for:43),"removing failed registration preserves successful peer")
        FocusStealPreventer.unregister(two)
        check(FocusStealPreventer.diagnostics()["taps"] as? Int==0,"last degraded registration releases remaining filters")
        Owned.reset();Owned.bridge=nil
        let noBridge=try SyntheticFocusController(pid:42,processKey:"p42")
        check(!Owned.trace.contains("create:keyboard:9") && FocusStealPreventer.diagnostics()["taps"] as? Int==2,"missing bridge skips only bridge filter")
        check(Owned.trace.firstIndex(of:"create:keyboard:42")! < Owned.trace.firstIndex(of:"create:observer:42")!,"protection registration precedes target observer")
        noBridge.close()
        for active in [false,true]{for focused in [false,true]{
            Owned.reset();Owned.active=active;Owned.focusPID=focused ? 42:0;Owned.frontmost=active ? 42:0
            Owned.noPort=Set(resources)
            let controller=try SyntheticFocusController(pid:42,processKey:"p42")
            check(controller.stateFixture==SyntheticFocusState(believesActive:active,believesFocused:focused,actuallyActive:active),"initial state after failed taps active=\(active) focused=\(focused)")
            controller.close()
        }}
        Owned.reset();let callbacks=try SyntheticFocusController(pid:42,processKey:"p42")
        let observer=Owned.ports["observer:42"]!
        _ = observer.callback(0,CGEventType(rawValue:20)!,CGEvent(),observer.pointer)
        check(callbacks.stateFixture.believesActive && callbacks.clickFocused,"successful target observer updates activation and focus")
        _ = observer.callback(0,.tapDisabledByTimeout,CGEvent(),observer.pointer)
        check(Owned.trace.last=="enable:observer:42:true","disabled observer is reenabled")
        callbacks.close();let previous=callbacks.stateFixture
        _ = observer.callback(0,CGEventType(rawValue:19)!,CGEvent(),observer.pointer)
        check(callbacks.stateFixture==previous,"late observer event cannot mutate closed controller")
        Owned.reset();let workspace=try SyntheticFocusController(pid:42,processKey:"p42")
        Owned.frontmost=42;NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.didActivateApplicationNotification,object:nil)
        check(workspace.stateFixture.actuallyActive,"workspace activity still updates actual state")
        NSWorkspace.shared.notificationCenter.post(name:NSWorkspace.didTerminateApplicationNotification,object:nil,userInfo:[NSWorkspace.applicationUserInfoKey:NSRunningApplication(processIdentifier:42)!])
        check(workspace.isClosed && FocusStealPreventer.registrationCount==0,"termination tears down partial or complete resources")
        Owned.reset();Owned.noPort=["global"];Owned.noSource=["keyboard:9"]
        let partial=try FocusStealPreventer.register(pid:42,processKey:"p42",lost:{},gained:{})
        Owned.trace=[];let keyboard=Owned.ports["keyboard:42"]!
        _ = keyboard.callback(0,.tapDisabledByUserInput,CGEvent(),keyboard.pointer)
        check(Set(Owned.trace)==Set(["enable:keyboard:9:true","enable:keyboard:42:true"]),"reenable visits available partial resources without requiring global tap")
        check(FocusStealPreventer.diagnostics()["taps"] as? Int==2 && !FocusStealPreventer.hasKeyboardFilter(for:9) && FocusStealPreventer.hasKeyboardFilter(for:42),"diagnostics distinguish retained ports from keyboard readiness")
        FocusStealPreventer.unregister(partial)
        let passed=rows.filter{$0["passed"] as? Bool==true}.count
        try JSONSerialization.data(withJSONObject:["passed":passed,"failed":rows.count-passed,"checks":rows,"installation_matrix_cases":81],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if passed != rows.count{exit(1)}
    }
}
