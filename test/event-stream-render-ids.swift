import Foundation

@main enum EventStreamRenderIDTests {
    static var checks=0
    static func check(_ label:String,_ result:@autoclosure()->Bool) {
        guard result() else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        typealias Node=EventStreamRenderedNode<Int>
        typealias Render=EventStreamRenderedTree<Int>
        typealias Source=EventStreamCollectedTree<Int>
        typealias Item=EventStreamCollectedItem<Int>
        func node(_ identity:Int,_ id:Int?=nil,_ path:[Int]?=nil,_ children:[Node]=[])->Node {
            .init(identity:identity,elementID:id,text:"node \(identity)",sourcePath:path,children:children)
        }
        if CommandLine.arguments.contains("--overflow") {
            var next=EventStreamNextRenderID(Render(isFocusTree:false,roots:[node(1,Int.max,[0])]))
            // Make the result observable: whole-module optimization may
            // eliminate a dead calculation, including its overflow trap.
            print(next.next())
            return // A returned value must make the parent reject this probe.
        }
        func source(_ id:Int,_ title:String,_ children:[Item]=[])->Item {
            var n=EventStreamTransformedNode(element:id);n.title=title
            return .init(node:n,path:[999],children:children,childrenSubset:nil)
        }
        let a=node(10,77,[0],[node(20,88,[0,0])]),b=node(30,99,[1])
        let main=Render(isFocusTree:false,roots:[a,b])
        EventStreamRenderIDs.setInitialIDs(main)
        check("root numbering starts at zero in depth-first order",main.preorder.compactMap(\.elementID)==[0,1,2])
        check("initial numbering overwrites previous numeric IDs",a.elementID==0 && b.elementID==2)
        let first=node(9,nil,[0]),second=node(9,nil,[1])
        let duplicates=Render(isFocusTree:true,roots:[first,second]);EventStreamRenderIDs.setInitialIDs(duplicates)
        check("initial numbering does not deduplicate native identity",first.elementID==0 && second.elementID==1)
        let duplicateTable=try EventStreamRenderIDs.assign(main:duplicates)
        check("duplicate native identity maps to its last numeric value",duplicateTable.values==[9:1])
        check("earlier numeric paths survive duplicate native identity",duplicateTable.paths==[0:[0],1:[1]])
        check("inverse table excludes superseded numeric identity",duplicateTable.elements[0]==nil && duplicateTable.elements[1]==9)
        var next=EventStreamNextRenderID(Render(isFocusTree:false,roots:[]))
        check("empty main tree allocator starts at one",next.next()==1)
        check("allocator increments consecutively after first next",next.next()==2 && next.next()==3)
        var noIDs=EventStreamNextRenderID(Render(isFocusTree:true,roots:[node(1,nil,[0])]))
        check("nonempty all-nil main IDs also start at one",noIDs.next()==1)
        var gaps=EventStreamNextRenderID(Render(isFocusTree:false,roots:[node(1,0,[0]),node(2,9,[1]),node(3,2,[2])]))
        check("allocator uses maximum rather than filling gaps",gaps.next()==10)
        var negative=EventStreamNextRenderID(Render(isFocusTree:false,roots:[node(1,-5,[0]),node(2,-3,[1])]))
        check("negative existing maxima are not clamped",negative.next() == -2 && negative.next() == -1)
        let mutable=node(1,2,[0]);var lazy=EventStreamNextRenderID(Render(isFocusTree:false,roots:[mutable]));mutable.elementID=40
        check("first maximum observes intervening reference mutation",lazy.next()==41)
        mutable.elementID=100
        check("later next ignores a changed main maximum",lazy.next()==42)
        let root=node(1,2,[0]);var snapshot=Render(isFocusTree:false,roots:[root]);var retained=EventStreamNextRenderID(snapshot)
        snapshot.roots.append(node(2,90,[1]))
        check("allocator retains the root-array value",retained.next()==3)
        let parent=node(1,2,[0]);var childMutation=EventStreamNextRenderID(Render(isFocusTree:false,roots:[parent]));parent.children.append(node(2,90,[0,0]))
        check("allocator observes children added through retained references",childMutation.next()==91)

        let m1=node(10,5,[0]),m2=node(20,nil,[1]),m3=node(20,nil,[2])
        let f1=node(10,nil,[0]),f2=node(30,nil,[0,0])
        let mixed=Render(isFocusTree:false,roots:[m1,m2,m3]),focus=Render(isFocusTree:true,roots:[f1,f2])
        let ids=try EventStreamRenderIDs.assign(main:mixed,focus:focus)
        check("existing main numeric ID remains present",m1.elementID==5)
        check("first missing main identity allocates after global maximum",m2.elementID==6)
        check("later duplicate identity reuses the earlier mapping",m3.elementID==6)
        check("focus identity reuses the main numeric ID",f1.elementID==5)
        check("focus-only identity gets next available main-based ID",f2.elementID==7)
        check("main then focus writes form shared native ID table",ids.values==[10:5,20:6,30:7] && ids.elements==[5:10,6:20,7:30])
        check("focus paths replace earlier main path for shared ID",ids.paths[5]==[0] && ids.paths[7]==[0,0])
        check("duplicate main mapping uses its last source path",ids.paths[6]==[2])
        let future=node(3,90,[2]),before=node(1,nil,[0]),later=node(2,nil,[1])
        _ = try EventStreamRenderIDs.assign(main:.init(isFocusTree:false,roots:[before,later,future]))
        check("first allocation scans IDs beyond current traversal prefix",before.elementID==91 && later.elementID==92)
        let prior=node(8,nil,[0]),override=node(8,50,[1]),after=node(8,nil,[2])
        let overrides=try EventStreamRenderIDs.assign(main:.init(isFocusTree:false,roots:[prior,override,after]))
        check("explicit existing ID overrides an earlier identity mapping",prior.elementID==51 && override.elementID==50 && after.elementID==50 && overrides.values[8]==50)
        check("overridden identities retain earlier path entries",overrides.paths[51]==[0] && overrides.paths[50]==[2])
        let explicitFocus=node(9,100,[0]),newFocus=node(8,nil,[1])
        _ = try EventStreamRenderIDs.assign(main:.init(isFocusTree:false,roots:[node(1,4,[0])]),focus:.init(isFocusTree:true,roots:[explicitFocus,newFocus]))
        check("allocator ignores preexisting focus maximum",explicitFocus.elementID==100 && newFocus.elementID==5)
        let only=node(3,nil,[0]);_ = try EventStreamRenderIDs.assign(main:.init(isFocusTree:false,roots:[]),focus:.init(isFocusTree:true,roots:[only]))
        check("focus-only forest with empty main starts at one",only.elementID==1)
        let empty=try EventStreamRenderIDs.assign(main:Render(isFocusTree:false,roots:[]))
        check("empty main and nil focus produce empty table",empty.values.isEmpty && empty.paths.isEmpty && empty.elements.isEmpty)
        let maxID=node(1,Int.max,[0]),reuse=node(1,nil,[0])
        _ = try EventStreamRenderIDs.assign(main:.init(isFocusTree:false,roots:[maxID]),focus:.init(isFocusTree:true,roots:[reuse]))
        check("existing maximum is safe when allocator is never used",reuse.elementID==Int.max)
        let old=node(1,17,[0]),new=node(2,4,[0]);EventStreamRenderIDs.inherit(from:old,to:new)
        check("paired inheritance copies old numeric ID over new ID",new.elementID==17)
        EventStreamRenderIDs.inherit(from:node(3,nil,[0]),to:new)
        check("absent old numeric ID does not erase existing new ID",new.elementID==17)

        let valid=node(1,nil,[0]),missing=node(2,40,nil),unvisited=node(3,nil,[2]);var caught=false
        do {_ = try EventStreamRenderIDs.assign(main:.init(isFocusTree:false,roots:[valid,missing,unvisited]))}
        catch let error as EventStreamMissingRenderSourcePath {
            caught=true;check("missing path error has its description",error.description=="Revision render trees must have source paths referencing the element tree.")
        }
        check("missing path throws while retaining prior ID effects",caught && valid.elementID==41 && missing.elementID==40)
        check("missing path prevents assignment to later nodes",unvisited.elementID==nil)
        let noPath=node(1,nil,nil);caught=false
        do {_ = try EventStreamRenderIDs.assign(main:.init(isFocusTree:false,roots:[noPath]))}catch is EventStreamMissingRenderSourcePath {caught=true}
        check("first missing path fails before ID mutation",caught && noPath.elementID==nil)
        let blankPath=node(7,nil,[]);let blankTable=try EventStreamRenderIDs.assign(main:.init(isFocusTree:false,roots:[blankPath]))
        check("present empty source path is retained rather than rejected",blankTable.paths[1]==[])
        let mainOnly=node(1,0,[0]),badFocus=node(2,nil,nil);caught=false
        do {_ = try EventStreamRenderIDs.assign(main:.init(isFocusTree:false,roots:[mainOnly]),focus:.init(isFocusTree:true,roots:[badFocus]))}catch is EventStreamMissingRenderSourcePath {caught=true}
        check("missing focus path preserves main assignments",caught && mainOnly.elementID==0 && badFocus.elementID==nil)

        let tree=Source(roots:[source(10,"main root",[source(20,"main child")]),source(30,"main other")])
        let focused=Source(roots:[source(10,"focus root",[source(20,"focus child")])])
        let table=EventStreamRenderIDTable(values:[10:0,20:1,30:2],paths:[0:[0],1:[0,0],2:[1]])
        check("shared identity resolves in focus tree first",EventStreamRenderIDs.item(for:1,in:table,tree:tree,focus:focused,identity:{$0})?.node.title=="focus child")
        check("focus membership includes its zero preorder index",EventStreamRenderIDs.item(for:0,in:table,tree:tree,focus:focused,identity:{$0})?.node.title=="focus root")
        check("main-only identity resolves its main path",EventStreamRenderIDs.item(for:2,in:table,tree:tree,focus:focused,identity:{$0})?.node.title=="main other")
        check("nil focus resolves a main item",EventStreamRenderIDs.item(for:1,in:table,tree:tree,identity:{$0})?.node.title=="main child")
        check("unknown numeric ID returns no item",EventStreamRenderIDs.item(for:99,in:table,tree:tree,focus:focused,identity:{$0})==nil)
        let orphan=EventStreamRenderIDTable(values:[10:1],paths:[0:[0]])
        check("path without inverse native identity does not resolve",EventStreamRenderIDs.item(for:0,in:orphan,tree:tree,identity:{$0})==nil)
        let noNumericPath=EventStreamRenderIDTable(values:[10:0],paths:[:])
        check("numeric identity without path does not resolve",EventStreamRenderIDs.item(for:0,in:noNumericPath,tree:tree,identity:{$0})==nil)
        for path in [[],[-1],[9],[0,-1],[0,9],[0,0,0]] {
            let invalid=EventStreamRenderIDTable(values:[10:0],paths:[0:path])
            check("invalid source path \(path) returns no item",EventStreamRenderIDs.item(for:0,in:invalid,tree:tree,identity:{$0})==nil)
        }
        let trusted=EventStreamRenderIDTable(values:[99:0],paths:[0:[0]])
        check("lookup trusts stored path without extra identity check",EventStreamRenderIDs.item(for:0,in:trusted,tree:tree,identity:{$0})?.node.element==10)
        let wrongFocusPath=EventStreamRenderIDTable(values:[20:0],paths:[0:[1]])
        check("focus path failure does not fall back to main",EventStreamRenderIDs.item(for:0,in:wrongFocusPath,tree:tree,focus:focused,identity:{$0})==nil)
        check("lookup preserves source hierarchy",tree.roots[0].children.count==1 && focused.roots[0].children.count==1)
        let process=Process();process.executableURL = .init(fileURLWithPath:CommandLine.arguments[0]);process.arguments=["--overflow"]
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice;try process.run();process.waitUntilExit()
        check("numeric ID overflow traps",process.terminationReason == .uncaughtSignal && process.terminationStatus != 0)
        print("EVENT STREAM RENDER IDS: \(checks) checks passed")
    }
}
