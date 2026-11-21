import Foundation
import CoreGraphics
import CoreFoundation
final class AXUIElement:NSObject {
    let id:Int;var role="AXButton",names=Set<String>(),settable=false,namesFail=false,settableFail=false,parent:AXUIElement?
    init(_ id:Int){self.id=id}
}
let kAXRoleAttribute="AXRole",kAXMenuItemRole="AXMenuItem",kAXMenuBarItemRole="AXMenuBarItem",kAXSelectedAttribute="AXSelected",kAXParentAttribute="AXParent"
enum Fault:Error{case owned}
enum Owned {
    static var trace=[String](),focused=false,active=false,catalyst=false,constructFail=false,pidFail=false,cancelled=false
    static var app=AXUIElement(0),window=AXUIElement(99),nextFocused=false
    static func reset(){trace=[];focused=false;active=false;catalyst=false;constructFail=false;pidFail=false;cancelled=false;app=AXUIElement(0);window=AXUIElement(99);nextFocused=false;SyntheticFocusSessions.reset()}
}
struct Running {let processIdentifier:Int32;let key:String}
struct ResolvedApp {let bundleIdentifier:String;let running:Running}
enum AppResolver {
    static var key="v1"
    static func require(_ bundle:String)throws->ResolvedApp{ResolvedApp(bundleIdentifier:bundle,running:Running(processIdentifier:42,key:key))}
    static func processKey(_ running:Running)->String{running.key}
}
final class NSRunningApplication {let isActive:Bool;init?(processIdentifier:Int32){isActive=Owned.active}}
enum AccessibilityWindowSPI {static func actualPID(_ el:AXUIElement)throws->Int32{Owned.trace.append("pid");if Owned.pidFail{throw Fault.owned};return 42}}
enum RequestRuntime {static func check()throws{if Owned.cancelled{throw Fault.owned}}}
enum AX {
    static func onElement<T>(_ el:AXUIElement,_ body:()throws->T)throws->T{Owned.trace.append("route:\(el.id)");return try body()}
    static func string(_ el:AXUIElement,_ attribute:String)->String?{Owned.trace.append("role:\(el.id)");return el.role}
    static func copy(_ el:AXUIElement,_ attribute:String)->AnyObject?{
        if attribute==kAXParentAttribute{return el.parent}
        if attribute=="_AXExhibitsMacCatalystBehavior"{Owned.trace.append("catalyst");return NSNumber(value:Owned.catalyst)}
        return nil
    }
    static func axElement(_ value:AnyObject?)->AXUIElement?{value as? AXUIElement}
}
enum Status {case success,failure}
func AXUIElementCopyAttributeNames(_ el:AXUIElement,_ names:inout CFArray?)->Status{Owned.trace.append("names:\(el.id)");names=Array(el.names) as CFArray;return el.namesFail ? .failure:.success}
func AXUIElementIsAttributeSettable(_ el:AXUIElement,_ name:CFString,_ value:inout DarwinBoolean)->Status{Owned.trace.append("settable:\(el.id)");value=DarwinBoolean(el.settable);return el.settableFail ? .failure:.success}
func AXUIElementCreateApplication(_ pid:Int32)->AXUIElement{Owned.app}
final class AXIndex {static let shared=AXIndex();struct Snapshot{let windowElement:AXUIElement?};func snapshot(for bundle:String)->Snapshot?{Snapshot(windowElement:Owned.window)}}
final class SyntheticFocusController {
    let pid:Int32,processKey:String;private let lock=NSLock();private var state:(believesActive:Bool,believesFocused:Bool,actuallyActive:Bool);var isClosed=false
    init(pid:Int32,processKey:String)throws{if Owned.constructFail{throw Fault.owned};self.pid=pid;self.processKey=processKey;state=(false,Owned.nextFocused,false);Owned.trace.append("construct")}
    func close(){isClosed=true;Owned.trace.append("close")}
    func enforce(window:AXUIElement?)throws{Owned.trace.append("enforce:\(window?.id ?? -1)")}
    func stateFixture(_ a:Bool,_ f:Bool,_ actual:Bool){state=(a,f,actual)}
    /* STATE */
}
enum SyntheticFocusSessions {
    private static let lock=NSLock();private static var controllers=[String:SyntheticFocusController]()
    static func reset(){controllers=[:]}
    /* SESSION */
}
/* ADAPTER */
@main struct FocusTests {
    static func main()throws{
        var rows=[[String:Any]]()
        func check(_ ok:Bool,_ name:String){rows.append(["name":name,"passed":ok]);print("\(ok ? "PASS":"FAIL") native click focus \(name)")}
        // Exhaust all truth-table combinations. The expected decisions follow
        // the policy's branch table; no native focus change is executed.
        for delivery in [NativeClickFocusPolicy.Delivery.accessibility,.mouse] {
            for focused in [false,true] {for held in [false,true] {for web in [false,true] {for catalyst in [false,true] {for select in [false,true] {for menu in [false,true] {
                var enforced=false
                let flags=try NativeClickFocusPolicy.prepare(delivery,focused:focused,heldKey:held,actualActive:{fatalError("unexpected fallback")},webShaped:{web},catalyst:{catalyst},maySelect:{select},menuButton:{menu},enforce:{enforced=true})
                let expected = !focused && (delivery == .mouse ? (held || web || select || (catalyst && menu)) : (catalyst && (select || menu)))
                let expectedFlags:UInt64 = delivery == .mouse && !focused && !expected ? 0x100000:0
                check(enforced==expected && flags==expectedFlags,"decision \(delivery) focused=\(focused) held=\(held) web=\(web) catalyst=\(catalyst) select=\(select) menu=\(menu)")
            }}}}}}
        }
        for delivery in [NativeClickFocusPolicy.Delivery.accessibility,.mouse] {for active in [false,true] {
            var reads=0
            let flags=try NativeClickFocusPolicy.prepare(delivery,focused:nil,heldKey:true,actualActive:{reads += 1;return active},webShaped:{fatalError()},catalyst:{fatalError()},maySelect:{fatalError()},menuButton:{fatalError()},enforce:{fatalError()})
            check(reads==1 && flags==(delivery == .mouse && !active ? 0x100000:0),"nil enforcer actual active \(delivery) \(active)")
        }}
        var order=[String](),selectReads=0
        let flags=try NativeClickFocusPolicy.prepare(.mouse,focused:false,heldKey:false,actualActive:{fatalError()},webShaped:{order.append("web");return false},catalyst:{order.append("catalyst");return true},maySelect:{selectReads += 1;order.append("select");return selectReads==2},menuButton:{fatalError()},enforce:{order.append("enforce")})
        check(flags==0 && order==["web","select","catalyst","select","enforce"],"Catalyst retries the selection query after the web and Catalyst checks")
        do{_ = try NativeClickFocusPolicy.prepare(.mouse,focused:false,heldKey:true,actualActive:{fatalError()},webShaped:{fatalError()},catalyst:{fatalError()},maySelect:{fatalError()},menuButton:{fatalError()},enforce:{throw Fault.owned});check(false,"enforcement failure propagates")}catch{check(true,"enforcement failure propagates")}
        Owned.reset();let element=AXUIElement(1)
        check(try !AXNativeClickFocus.mayCauseSelection(element),"ordinary node does not select")
        element.names=["AXSelected"];element.settable=true
        check(try AXNativeClickFocus.mayCauseSelection(element),"supported settable selected node selects")
        element.names=[]
        check(try !AXNativeClickFocus.mayCauseSelection(element),"unadvertised selected capability is not queried")
        for attribute in ["AXSelectedRows","AXSelectedCells","AXSelectedChildren"]{element.names=[attribute];check(try AXNativeClickFocus.mayCauseSelection(element),"selection relation \(attribute)")}
        for role in ["AXMenuItem","AXMenuBarItem"]{element.role=role;element.names=["AXSelected"];check(try !AXNativeClickFocus.mayCauseSelection(element),"menu role excludes selectable setter \(role)")}
        element.role="AXButton";element.names=["AXSelected"];element.settableFail=true
        check(try !AXNativeClickFocus.mayCauseSelection(element),"settable error is false")
        element.settableFail=false;element.namesFail=true
        check(try !AXNativeClickFocus.mayCauseSelection(element),"attribute-name error is empty")
        Owned.reset();let child=AXUIElement(1),app=AXUIElement(2),above=AXUIElement(3);child.parent=app;app.parent=above;app.role="AXApplication";above.names=["AXSelectedRows"]
        check(try !AXNativeClickFocus.mayCauseSelection(child),"application terminates ancestor selection search")
        for depth in [300,301]{let start=AXUIElement(1);var node=start;for i in 1...depth{let parent=AXUIElement(i+1);node.parent=parent;node=parent};node.names=["AXSelectedRows"];check(try AXNativeClickFocus.mayCauseSelection(start)==(depth==300),"selection depth \(depth)")}
        let cycle=AXUIElement(4);cycle.parent=cycle;check(try !AXNativeClickFocus.mayCauseSelection(cycle),"malformed ancestry cycle remains bounded")
        Owned.cancelled=true;do{_ = try AXNativeClickFocus.mayCauseSelection(child);check(false,"selection cancellation propagates")}catch{check(true,"selection cancellation propagates")}
        Owned.reset();AppResolver.key="v1";let resolved=try AppResolver.require("owned.fixture")
        let controller=try SyntheticFocusSessions.prepare(app:resolved);let again=try SyntheticFocusSessions.prepare(app:resolved)
        check(controller === again && Owned.trace==["construct"],"session prepare reuses same process without enforcing focus")
        for a in [false,true]{for f in [false,true]{for active in [false,true]{controller.stateFixture(a,f,active);check(controller.clickFocused==f,"focus byte uses believesFocused \(a) \(f) \(active)")}}}
        check(SyntheticFocusSessions.clickController(app:resolved) === controller,"click controller resolves session identity")
        AppResolver.key="v2";let changed=try AppResolver.require("owned.fixture");let replacement=try SyntheticFocusSessions.prepare(app:changed)
        check(replacement !== controller && controller.isClosed && SyntheticFocusSessions.clickController(app:resolved)==nil,"process replacement closes stale controller")
        replacement.close();let reopened=try SyntheticFocusSessions.prepare(app:changed);check(reopened !== replacement,"closed controller is recreated")
        Owned.reset();Owned.constructFail=true;do{_ = try SyntheticFocusSessions.prepare(app:resolved);check(false,"construction failure propagates")}catch{check(SyntheticFocusSessions.clickController(app:resolved)==nil,"construction failure propagates")}
        Owned.reset();AppResolver.key="v1";let button=AXUIElement(7)
        let background=try AXNativeClickFocus.prepare(button,bundle:"owned.fixture",delivery:.mouse,heldKey:false,webShaped:{false})
        check(background.rawValue==0x100000 && !Owned.trace.contains(where:{$0.hasPrefix("enforce")}),"missing enforcer inactive app yields background command flag")
        let _=try SyntheticFocusSessions.prepare(app:AppResolver.require("owned.fixture"));Owned.trace=[];Owned.catalyst=true;button.role="AXMenuButton"
        let prepared=try AXNativeClickFocus.prepare(button,bundle:"owned.fixture",delivery:.accessibility,heldKey:false,webShaped:{fatalError()})
        check(prepared.isEmpty && Owned.trace.contains("enforce:99"),"AX Catalyst menu button enforces selected snapshot window")
        Owned.trace=[];let mouse=try AXNativeClickFocus.prepare(button,bundle:"owned.fixture",delivery:.mouse,heldKey:true,webShaped:{fatalError()})
        check(mouse.isEmpty && Owned.trace==["enforce:99"],"held-key mouse enforces without unrelated metadata reads")
        Owned.reset();Owned.pidFail=true;do{_ = try AXNativeClickFocus.prepare(button,bundle:"owned.fixture",delivery:.accessibility,heldKey:false,webShaped:{false});check(false,"fallback actual PID error propagates")}catch{check(true,"fallback actual PID error propagates")}
        for catalyst in [false,true] {
            Owned.reset();let _=try SyntheticFocusSessions.prepare(app:AppResolver.require("owned.fixture"));Owned.trace=[];Owned.catalyst=catalyst
            let absent=try AXNativeClickFocus.prepare(nil,bundle:"owned.fixture",delivery:.mouse,heldKey:false,webShaped:{false})
            check(absent.rawValue==0x100000 && !Owned.trace.contains(where:{$0.hasPrefix("enforce") || $0.hasPrefix("role:") || $0.hasPrefix("names:")}),"absent coordinate hit skips element metadata catalyst=\(catalyst)")
        }
        Owned.reset();let _=try SyntheticFocusSessions.prepare(app:AppResolver.require("owned.fixture"));Owned.trace=[]
        let heldAbsent=try AXNativeClickFocus.prepare(nil,bundle:"owned.fixture",delivery:.mouse,heldKey:true,webShaped:{fatalError()})
        check(heldAbsent.isEmpty && Owned.trace==["enforce:99"],"held coordinate key enforces with absent hit")
        let passed=rows.filter{$0["passed"] as? Bool==true}.count
        try JSONSerialization.data(withJSONObject:["passed":passed,"failed":rows.count-passed,"checks":rows],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if passed != rows.count{exit(1)}
    }
}
