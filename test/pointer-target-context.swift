import Foundation
import CoreFoundation

final class AXUIElement: NSObject {
    let id: Int; var pid: Int32 = 42, windowID: UInt32 = 12, bounds = CGRect(x:0,y:0,width:600,height:400)
    var window: AXUIElement?, children = [AXUIElement](), remote: PointerTarget?, axFrame: CGRect?
    init(_ id: Int) { self.id=id }
}
let kAXWindowsAttribute="AXWindows",kAXFocusedWindowAttribute="AXFocusedWindow",kAXMainWindowAttribute="AXMainWindow"
let kAXPositionAttribute="AXPosition",kAXSizeAttribute="AXSize"
let kCGWindowNumber="Number",kCGNullWindowID: UInt32 = 0
struct WindowOptions: OptionSet { let rawValue:Int;static let optionOnScreenOnly=Self(rawValue:1),excludeDesktopElements=Self(rawValue:2) }
func CGWindowListCopyWindowInfo(_ options: WindowOptions,_ window: UInt32) -> AnyObject? { Owned.ids.map{[kCGWindowNumber:NSNumber(value:$0)]} as NSArray }
func AXUIElementCreateApplication(_ pid:Int32)->AXUIElement { Owned.app }
func AXUIElementCreateSystemWide()->AXUIElement { Owned.system }
func AXUIElementSetMessagingTimeout(_ el:AXUIElement,_ seconds:Float) {}
enum Fault:Error {case owned}
enum Owned {
    static var app=AXUIElement(0),system=AXUIElement(-1),window=AXUIElement(10),hit:AXUIElement?,global:AXUIElement?
    static var ids:[UInt32]=[12],front:UInt32?=12,trace=[String](),fault:String?
    static var extraWindows=[AXUIElement](),registered:[(element:AXUIElement,id:UInt32,isMenu:Bool)]?
    static func phase(_ phase:String)throws{trace.append(phase);if fault==phase{throw Fault.owned}}
    static func reset(){app=AXUIElement(0);system=AXUIElement(-1);window=AXUIElement(10);hit=AXUIElement(5);hit?.window=window;global=nil;ids=[12];front=12;trace=[];fault=nil;extraWindows=[];registered=nil}
}
enum RequestRuntime {static func check()throws{try Owned.phase("check")}}
enum AX {
    static func copy(_ el:AXUIElement,_ attribute:String)->AnyObject?{attribute==kAXWindowsAttribute ? ([Owned.window]+Owned.extraWindows) as NSArray : nil}
    static func axElement(_ object:AnyObject?)->AXUIElement?{object as? AXUIElement}
    static func window(of el:AXUIElement)throws->AXUIElement?{el.window}
    static func children(_ el:AXUIElement)->[AXUIElement]{el.children}
    static func point(_ el:AXUIElement,_ name:String)->CGPoint?{el.bounds.origin}
    static func size(_ el:AXUIElement,_ name:String)->CGSize?{el.bounds.size}
    static func rectangle(_ el:AXUIElement,_ name:String)->CGRect?{el.axFrame}
}
enum AccessibilityWindowSPI {
    static func windowID(_ el:AXUIElement)throws->UInt32{el.windowID}
    static func actualPID(_ el:AXUIElement)throws->Int32{el.pid}
}
enum Capture {static func currentFrame(windowID:UInt32,pid:Int32)->CGRect?{Owned.window.bounds}}
enum AXMenuSessions {static func pointerWindows(pid:Int32)->[(element:AXUIElement,id:UInt32,isMenu:Bool)]{Owned.registered ?? [(Owned.window,12,false)]}}
enum AXPointerTarget {
    /* RESOLVED */
    /* METHODS */
    /* FRAMES */
    static func hitTest(_ el:AXUIElement,x:Float,y:Float)throws->AXUIElement?{
        let global=el === Owned.system;try Owned.phase(global ? "system-hit":"app-hit");return global ? Owned.global:Owned.hit
    }
    static func remoteTarget(_ el:AXUIElement,hostPID:Int32)throws->PointerTarget?{try Owned.phase("remote:\(el.id)");return el.remote}
    static func frontWindowID(at point:CGPoint)->UInt32?{Owned.front}
    static func refinedTarget(_ el:AXUIElement,hostPID:Int32)throws->PointerTarget{
        try Owned.phase("refine:\(el.id)");return el.remote ?? PointerTarget(windowID:el.windowID,ownerPID:el.pid,screenFrame:Owned.window.bounds)
    }
    static func requireCurrent(_ target:PointerTarget)throws{try Owned.phase("current")}
}
@main enum ContextTests {
    static func main()throws{
        var rows=[[String:Any]]()
        func check(_ pass:Bool,_ name:String){rows.append(["name":name,"passed":pass]);print("\(pass ? "PASS":"FAIL") pointer context \(name)")}
        func resolve()throws->AXPointerTarget.Resolved{try AXPointerTarget.resolveContext(at:CGPoint(x:40,y:50),hostPID:42)}
        Owned.reset();let initial=Owned.hit;let first=try resolve()
        check(first.element === initial && first.pointer.windowID==12 && first.pointer.eventPID==42,"app-local hit retained with selected window")
        Owned.reset();Owned.window.axFrame=CGRect(x:20,y:30,width:60,height:70);let frameFirst=try resolve()
        check(frameFirst.pointer.screenFrame==Owned.window.bounds,"AXFrame containment is separate from WindowServer delivery bounds")
        Owned.reset();Owned.window.axFrame=CGRect(x:300,y:300,width:60,height:70)
        do{_ = try resolve();check(false,"AXFrame priority rejects a point outside it")}catch MouseTargeting.Failure.windowNotFoundAtPosition{check(!Owned.trace.contains("app-hit"),"AXFrame has priority over conflicting position/size before hit testing")}
        Owned.reset();Owned.window.axFrame = .zero
        do{_ = try resolve();check(false,"invalid present AXFrame must not fall back")}catch MouseTargeting.Failure.windowNotFoundAtPosition{check(!Owned.trace.contains("app-hit"),"present zero AXFrame does not invent position/size fallback")}
        Owned.reset();Owned.hit=nil;let absent=try resolve();check(absent.element==nil && absent.pointer.windowID==12,"nil app hit retains nil context")
        Owned.reset();let child=AXUIElement(6);Owned.hit?.children=[child];let parent=Owned.hit;let withChild = try resolve()
        check(Owned.trace.contains("remote:6") && !Owned.trace.contains("remote:5") && withChild.element === parent,"child used for remote detection does not replace retained ordinary hit")
        Owned.reset();Owned.hit?.remote=PointerTarget(windowID:99,ownerPID:50,screenFrame:Owned.window.bounds,eventPID:900,requireOnscreen:false);let remote=try resolve()
        check(remote.element==nil && remote.pointer.windowID==99 && remote.pointer.eventPID==900 && !remote.pointer.requireOnscreen && remote.cursorWindowID==12,"backing window fallback clears local hit and keeps distinct event PID and visual window")
        Owned.reset();Owned.window.pid=50;let other=try resolve();check(other.element==nil && other.pointer.ownerPID==50,"different selected window owner clears local hit")
        Owned.reset();let global=AXUIElement(7);global.windowID=44;Owned.global=global;let refined=try resolve()
        check(refined.element === global && refined.pointer.windowID==44 && refined.cursorWindowID==12,"successful system hit replaces target and metadata while preserving visual window")
        Owned.reset();let hosted=AXUIElement(8);hosted.remote=PointerTarget(windowID:55,ownerPID:51,screenFrame:Owned.window.bounds,eventPID:901);Owned.global=hosted;let hostedResult=try resolve()
        check(hostedResult.element === hosted && hostedResult.pointer.eventPID==901,"refined hosted hit is retained unlike app fallback")
        Owned.reset();Owned.registered=[(Owned.window,12,true)];let selectedMenu=Owned.window;let menu=try resolve()
        check(menu.menu === selectedMenu && menu.cursorWindowID==12 && menu.element === Owned.hit,"typed selected menu is retained independently of the hit element")
        Owned.reset();Owned.registered=[(Owned.window,12,true)];Owned.hit?.remote=PointerTarget(windowID:99,ownerPID:50,screenFrame:Owned.window.bounds,eventPID:900,requireOnscreen:false)
        let menuRemote=try resolve();check(menuRemote.menu === Owned.window && menuRemote.element==nil && menuRemote.pointer.eventPID==900,"remote fallback preserves concrete menu while clearing only its app-local hit")
        Owned.reset();Owned.registered=[(Owned.window,12,true)];let refinedHit=AXUIElement(99);refinedHit.windowID=44;Owned.global=refinedHit
        let menuRefined=try resolve();check(menuRefined.menu === Owned.window && menuRefined.element === refinedHit && menuRefined.pointer.windowID==44 && menuRefined.cursorWindowID==12,"global refinement preserves raw menu and visual identity while replacing delivery target")
        for front: UInt32? in [nil,13] {Owned.reset();Owned.front=front;Owned.global=AXUIElement(7);let skipped=try resolve();check(skipped.element === Owned.hit && !Owned.trace.contains("system-hit"),"unmatched front window skips global hit \(String(describing:front))")}
        for phase in ["app-hit","remote:5","system-hit","refine:7","current"] {
            Owned.reset();Owned.global=AXUIElement(7);Owned.fault=phase
            do{_ = try resolve();check(false,"target failure propagates \(phase)")}catch{check(true,"target failure propagates \(phase)")}
        }
        Owned.reset();Owned.global=AXUIElement(7);let compat=try AXPointerTarget.resolve(at:CGPoint(x:40,y:50),hostPID:42)
        check(compat.windowID==12,"legacy pointer-only API delegates to same context resolution")
        Owned.reset();let decoy=AXUIElement(20);decoy.windowID=13;Owned.extraWindows=[decoy];Owned.ids=[13,12];Owned.front=13;Owned.hit?.window=decoy
        let scoped=try resolve();check(scoped.pointer.windowID==12 && !Owned.trace.contains("system-hit"),"pre-existing overlapping decoy is not admitted by focus or app hit")
        let legacy=try AXPointerTarget.resolve(at:CGPoint(x:40,y:50),hostPID:42);check(legacy.windowID==13,"legacy resolver keeps its full AX-window behavior")
        Owned.registered=[(decoy,13,false),(Owned.window,12,false)];let admitted=try resolve();check(admitted.pointer.windowID==13,"registered creation can admit another window in stacking order")
        Owned.reset();Owned.registered=[]
        do{_ = try resolve();check(false,"empty registered set cannot fall back to AX windows")}catch MouseTargeting.Failure.noWindowsAvailable{check(!Owned.trace.contains("app-hit"),"empty registered set rejects before app hit with noWindowsAvailable")}catch{check(false,"unexpected empty-registry error: \(error)")}
        Owned.reset();Owned.registered=[(Owned.window,99,false)]
        do{_ = try resolve();check(false,"stored registry ID must be present in WindowServer order")}catch MouseTargeting.Failure.noWindowsAvailable{check(!Owned.trace.contains("app-hit"),"stored registry ID outside WindowServer order gives noWindowsAvailable")}catch{check(false,"unexpected missing-order error: \(error)")}
        Owned.reset()
        do{_ = try AXPointerTarget.resolveContext(at:CGPoint(x:860,y:130),hostPID:42);check(false,"outside registered frames rejects")}catch MouseTargeting.Failure.windowNotFoundAtPosition(let point){check(point.x==860 && point.y==130 && !Owned.trace.contains("app-hit") && !Owned.trace.contains("remote:5") && !Owned.trace.contains("system-hit"),"outside registered frames reports the requested point before app hit and refinement")}catch{check(false,"unexpected outside-frame error: \(error)")}
        Owned.reset()
        do{_ = try AXPointerTarget.resolve(at:CGPoint(x:860,y:130),hostPID:42);check(false,"legacy outside-frame rejects")}catch let error as ServiceError{check(error.code == .accessibilityError,"legacy outside-frame classification is preserved")}catch{check(false,"unexpected legacy outside-frame error: \(error)")}
        Owned.reset()
        let initialPoint=ScreenshotGeometry.NativeLayout.uninitialized.screenPoint(from:CGPoint(x:40,y:50))
        do{_ = try AXPointerTarget.resolveContext(at:initialPoint,hostPID:42);check(false,"uninitialized native mapping rejects")}catch MouseTargeting.Failure.windowNotFoundAtPosition(let point){check(point.x.isInfinite && point.y.isInfinite && !Owned.trace.contains("app-hit"),"initial null mapping reports the unmapped point without an AX hit")}catch{check(false,"unexpected initial-mapping error: \(error)")}
        let passed=rows.filter{$0["passed"] as? Bool==true}.count
        try JSONSerialization.data(withJSONObject:["passed":passed,"failed":rows.count-passed,"checks":rows],options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if passed != rows.count{exit(1)}
    }
}
