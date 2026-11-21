import Foundation
import CoreFoundation

typealias CGWindowID=UInt32
final class AXUIElement: NSObject { let id:Int;init(_ id:Int){self.id=id} }
/* MEMBERSHIP */
final class AXWindowOrderingObserver {
    private let lock=NSLock();private var stopped=false;private var windows=AXWindowMembership<AXUIElement>()
    var prunes=0
    func prune(){prunes += 1}
    func track(_ el:AXUIElement,_ id:UInt32){windows.track(el,id:id)}
    func stop(){stopped=true;windows=AXWindowMembership()}
    /* OBSERVER */
}
enum Owned {static var running=true,terminated=false,key="current",lookups=0}
final class NSRunningApplication {let isTerminated:Bool,key:String;init?(processIdentifier:Int32){Owned.lookups += 1;if !Owned.running{return nil};isTerminated=Owned.terminated;key=Owned.key}}
enum AppResolver {static func processKey(_ app:NSRunningApplication)->String{app.key}}
enum AXMenuSessions {
    final class Session {let pid:Int32,processKey:String,ordering:AXWindowOrderingObserver;init(_ pid:Int32,_ key:String,_ ordering:AXWindowOrderingObserver){self.pid=pid;processKey=key;self.ordering=ordering}}
    private static let lock=NSLock();private static var sessions=[String:Session]()
    static func reset(){sessions=[:];Owned.running=true;Owned.terminated=false;Owned.key="current";Owned.lookups=0}
    static func add(_ name:String,_ value:Session){sessions[name]=value}
    /* SESSIONS */
}
@main enum RegistryTests {
    static func main()throws{
        var rows=[[String:Any]]()
        func check(_ pass:Bool,_ name:String){rows.append(["name":name,"passed":pass]);print("\(pass ? "PASS":"FAIL") pointer registry \(name)")}
        AXMenuSessions.reset();check(AXMenuSessions.pointerWindows(pid:42).isEmpty && Owned.lookups==0,"missing native session does not query or invent another process")
        let observer=AXWindowOrderingObserver(),el=AXUIElement(7);observer.track(el,77)
        AXMenuSessions.add("owner",.init(42,"current",observer));let found=AXMenuSessions.pointerWindows(pid:42)
        check(found.count==1 && found[0].element === el && found[0].id==77 && observer.prunes==1,"current process returns raw element and registered ID after pruning")
        check(AXMenuSessions.pointerWindows(pid:43).isEmpty && Owned.lookups==1,"unrelated PID cannot borrow another session registry")
        Owned.running=false;check(AXMenuSessions.pointerWindows(pid:42).isEmpty && observer.prunes==1,"missing process blocks stale registry")
        Owned.running=true;Owned.terminated=true;check(AXMenuSessions.pointerWindows(pid:42).isEmpty && observer.prunes==1,"terminated process blocks stale registry")
        Owned.terminated=false;Owned.key="replacement";check(AXMenuSessions.pointerWindows(pid:42).isEmpty && observer.prunes==1,"PID reuse with new process key blocks stale registry")
        Owned.key="current";let second=AXUIElement(8);observer.track(second,88);let pair=AXMenuSessions.pointerWindows(pid:42)
        check(Set(pair.map{$0.id})==[77,88],"registered windows remain independent before stacking-order selection")
        observer.stop();check(AXMenuSessions.pointerWindows(pid:42).isEmpty,"closed observer cannot publish an old pointer target")
        AXMenuSessions.reset();let empty=AXWindowOrderingObserver();AXMenuSessions.add("empty",.init(42,"current",empty))
        check(AXMenuSessions.pointerWindows(pid:42).isEmpty && empty.prunes==1,"live empty registry has no AX-enumeration fallback")
        let passed=rows.filter{$0["passed"] as? Bool==true}.count
        try JSONSerialization.data(withJSONObject:["passed":passed,"failed":rows.count-passed,"checks":rows],options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if passed != rows.count{exit(1)}
    }
}
