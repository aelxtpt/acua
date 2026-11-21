import Foundation
typealias CGWindowID=UInt32
final class AXUIElement:NSObject {let name:String;init(_ name:String){self.name=name}}
/* MEMBERSHIP */
enum Fault:Error {case query}
enum AccessibilityWindowSPI {
    static var values=[String:UInt32](),errors=Set<String>(),reads=[String](),duringRead:(()->Void)?
    static func windowID(_ element:AXUIElement)throws->UInt32 {
        reads.append(element.name)
        let result=values[element.name] ?? 1
        let callback=duringRead;duringRead=nil;callback?()
        if errors.contains(element.name){throw Fault.query};return result
    }
}
final class AXWindowOrderingObserver {
    private let lock=NSLock()
    private var stopped=false,pruning=false
    private var windows=AXWindowMembership<AXUIElement>()
    func mutateWindows(_ body:(inout AXWindowMembership<AXUIElement>)->Void){lock.withLock{if !stopped{body(&windows)}}}
    func track(_ element:AXUIElement,id:UInt32){mutateWindows{$0.track(element,id:id)}}
    func remove(_ element:AXUIElement){mutateWindows{$0.remove(element)}}
    /* PRUNE */
    /* POINTER */
    /* MENU */
    func stop(){lock.withLock{stopped=true;windows=AXWindowMembership()}}
}
@main enum Tests {
    static func main()throws{
        var rows=[[String:Any]]()
        func check(_ value:Bool,_ name:String){rows.append(["name":name,"passed":value]);print("\(value ? "PASS":"FAIL") typed registry \(name)")}
        var membership=AXWindowMembership<String>()
        membership.track("main",id:10);membership.trackMenu("parent-menu",id:20);membership.trackMenu("child-menu",id:30)
        membership.remove("parent-menu")
        check(membership.ids==[10,30] && membership.entries[30]?.isMenu==true,"matching close preserves nested menu and ordinary entries")
        membership.trackMenu("replacement",id:10);membership.remove("main")
        check(membership.entries[10]?.element=="replacement" && membership.entries[10]?.isMenu==true,"CG ID upsert replaces raw identity and concrete kind")
        membership.track("replacement",id:40);membership.remove("replacement")
        check(membership.ids==[30],"raw equality removes matching aliases across IDs and kinds")
        let invalid=membership.entries
        membership.trackMenu("child-menu",id:30);membership.removeInvalid(invalid)
        check(membership.ids==[30],"replacement generation cannot be removed by a stale validity result")
        membership.removeInvalid(membership.entries)
        check(membership.ids.isEmpty,"unchanged invalid entry is removed")
        membership.track("main",id:10);membership.trackMenu("menu",id:20);membership.closeMenus()
        check(membership.ids==[10],"session-wide menu retirement preserves ordinary records")
        let observer=AXWindowOrderingObserver(),main=AXUIElement("main"),menu=AXUIElement("menu"),child=AXUIElement("child")
        observer.track(main,id:10);let observed=observer.trackMenu(menu,id:20);_ = observer.trackMenu(child,id:30)
        check(observed==[10,20],"menu registration retains raw element without requiring an action token")
        let all=observer.pointerWindows()
        check(Set(all.map{$0.id})==[10,20,30] && all.first(where:{$0.id==20})?.element === menu && all.first(where:{$0.id==20})?.isMenu==true,"pointer snapshot publishes menu raw identity and kind")
        AccessibilityWindowSPI.values["menu"]=0
        AccessibilityWindowSPI.errors=["child"]
        AccessibilityWindowSPI.reads=[]
        let pruned=observer.pointerWindows()
        check(pruned.count==1 && pruned[0].element === main && Set(AccessibilityWindowSPI.reads)==["main","menu","child"],"actual prune discards zero raw window ID and query errors for menus")
        AccessibilityWindowSPI.errors=[];AccessibilityWindowSPI.values["menu"]=1
        _ = observer.trackMenu(menu,id:20)
        AccessibilityWindowSPI.values["main"]=0
        observer.prune()
        check(observer.pointerWindows().map{$0.id}==[20],"actual prune also rejects an invalid ordinary window")
        AccessibilityWindowSPI.values["menu"]=0
        AccessibilityWindowSPI.duringRead={AccessibilityWindowSPI.values["menu"]=1;_ = observer.trackMenu(menu,id:20)}
        observer.prune()
        check(observer.pointerWindows().map{$0.id}==[20],"stale zero result does not erase re-registered menu with same raw element and ID")
        observer.remove(menu)
        check(observer.pointerWindows().isEmpty,"physical close removes exactly the matching menu")
        _ = observer.trackMenu(menu,id:20);observer.stop();_ = observer.trackMenu(child,id:30)
        check(observer.pointerWindows().isEmpty,"stopped registry rejects late menu publication")
        let passed=rows.filter{$0["passed"] as? Bool==true}.count
        try JSONSerialization.data(withJSONObject:["passed":passed,"failed":rows.count-passed,"checks":rows],options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if passed != rows.count {exit(1)}
    }
}
