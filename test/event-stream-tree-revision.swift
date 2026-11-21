import Foundation

@main enum EventStreamTreeRevisionTests {
    typealias Node=EventStreamRenderedNode<Int>
    typealias Render=EventStreamRenderedTree<Int>
    typealias Source=EventStreamCollectedTree<Int>
    typealias Revision=EventStreamTreeRevision<Int,Int>
    static var checks=0
    enum Probe:Error {case main,focus}
    static func check(_ label:String,_ result:@autoclosure()throws->Bool) {
        guard (try? result())==true else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    static func node(_ id:Int,_ text:String?=nil,_ path:[Int]?=[0],_ children:[Node]=[])->Node {
        .init(identity:id,text:text ?? "node \(id)",sourcePath:path,children:children)
    }
    static func source(_ ids:[Int])->Source {
        .init(roots:ids.map {.init(node:.init(element:$0),path:[999],children:[],childrenSubset:nil)})
    }
    static func render(_ nodes:[Node],focus:Bool=false)->Render {.init(isFocusTree:focus,roots:nodes)}
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        if let probe=CommandLine.arguments.first(where:{$0.hasPrefix("--trap-")}) {
            switch probe {
            case "--trap-parent-negative":_=EventStreamRenderSnapshot(subjectID:"x",isFocus:false,renders:[.init(id:0,text:"x",parentIndex:-1)]).renderTree()
            case "--trap-parent-future":_=EventStreamRenderSnapshot(subjectID:"x",isFocus:false,renders:[.init(id:0,text:"x",parentIndex:1)]).renderTree()
            case "--trap-time-negative":_=EventStreamTimestampUUID.make(timestamp:.init(timeIntervalSince1970:-0.001),randomBytes:{Array(repeating:0,count:16)})
            case "--trap-time-nan":_=EventStreamTimestampUUID.make(timestamp:.init(timeIntervalSince1970:.nan),randomBytes:{Array(repeating:0,count:16)})
            case "--trap-time-infinite":_=EventStreamTimestampUUID.make(timestamp:.init(timeIntervalSince1970:.infinity),randomBytes:{Array(repeating:0,count:16)})
            case "--trap-time-upper":_=EventStreamTimestampUUID.make(timestamp:.init(timeIntervalSince1970:Double(UInt64.max)/1000),randomBytes:{Array(repeating:0,count:16)})
            default:fatalError("unknown probe")
            }
            return // A normal return rejects the parent's trapping assertion.
        }
        let input=source([10,20]),focused=source([10,30])
        let a=node(10),b=node(20,nil,[1]),f=node(10),g=node(30,nil,[1])
        a.elementID=77;b.elementID=88
        var calls:[Int]=[],observedMainIDs:[Int?]=[]
        let root=try Revision.root(input,focusTree:focused,lineageID:"Exact Lineage",identity:{$0}) {tree in
            calls.append(tree.roots.last!.node.element)
            if calls.count==1 {return render([a,b])}
            observedMainIDs=[a.elementID,b.elementID]
            return render([f,g],focus:true)
        }
        check("root renders main before optional focus",calls==[20,30])
        check("main initial numbering precedes focus callback",observedMainIDs==[0,1])
        check("root overwrites preexisting main IDs",a.elementID==0 && b.elementID==1)
        check("root shares numeric identity map with focus",f.elementID==0 && g.elementID==2 && root.ids.values==[10:0,20:1,30:2])
        check("root retains exact supplied lineage",root.lineageID=="Exact Lineage")
        check("root has no predecessor and no changes",root.previousRevision==nil && root.changes.isEmpty && root.lineageRootRevision===root)
        check("root retains source tree values",root.tree.roots.map {$0.node.element}==[10,20] && root.focusTree?.roots.map {$0.node.element}==[10,30])
        check("root retains rendered references and focus flag",root.renderTree.roots[0]===a && root.focusRenderTree?.roots[1]===g && root.focusRenderTree?.isFocusTree==true)
        check("revision item chooses focus source when shared",root.element(for:2)==30 && root.item(for:0)?.node.element==10)
        check("revision element lookup rejects unknown ID",root.element(for:999)==nil)
        var nilCalls=0
        let nilFocus=try Revision.root(source([]),lineageID:"",identity:{$0}) {_ in nilCalls += 1;return render([])}
        check("nil focus skips render and keeps optional trees absent",nilCalls==1 && nilFocus.focusTree==nil && nilFocus.focusRenderTree==nil)
        check("empty lineage remains supplied empty string",nilFocus.lineageID.isEmpty)
        var emptyCalls=0
        let emptyFocus=try Revision.root(source([]),focusTree:source([]),lineageID:"empty",identity:{$0}) {_ in emptyCalls += 1;return render([])}
        check("present empty focus still invokes renderer",emptyCalls==2 && emptyFocus.focusTree != nil && emptyFocus.focusRenderTree != nil)
        check("present empty focus yields empty present snapshot",try emptyFocus.focusRenderTreeSnapshot()?.renders.isEmpty==true)
        check("nil focus snapshot remains nil",try nilFocus.focusRenderTreeSnapshot()==nil)
        let fallback=try Revision(tree:source([]),renderTree:render([]),identity:{$0})
        check("generic constructor fallback is uppercase UUID",UUID(uuidString:fallback.lineageID) != nil && fallback.lineageID==fallback.lineageID.uppercased())
        let preferred=try Revision(tree:source([]),renderTree:render([]),lineageID:"ignore me",previousRevision:root,identity:{$0})
        check("previous lineage wins over explicitly provided lineage",preferred.lineageID==root.lineageID && preferred.previousRevision===root)
        let failedMain=node(1);failedMain.elementID=99;var failedCalls=0
        do {
            _=try Revision.root(source([1]),focusTree:source([2]),lineageID:"x",identity:{$0}) {_ in failedCalls += 1;throw Probe.main}
            fatalError("FAIL: main renderer must throw")
        } catch Probe.main {}
        check("main render failure skips later stages",failedCalls==1 && failedMain.elementID==99)
        let numberedBeforeFailure=node(1);var focusCalls=0
        do {
            _=try Revision.root(source([1]),focusTree:source([2]),lineageID:"x",identity:{$0}) {_ in
                focusCalls += 1
                if focusCalls==1 {return render([numberedBeforeFailure])}
                throw Probe.focus
            }
            fatalError("FAIL: focus renderer must throw")
        } catch Probe.focus {}
        check("focus failure retains earlier root numbering",focusCalls==2 && numberedBeforeFailure.elementID==0)
        let missing=node(1,nil,nil),prior=node(2,nil,[1]);var missingCalls=0
        do {
            _=try Revision.root(source([1,2]),focusTree:source([]),lineageID:"x",identity:{$0}) {_ in
                missingCalls += 1;return missingCalls==1 ? render([missing,prior]):render([])
            }
            fatalError("FAIL: missing source path must throw")
        } catch is EventStreamMissingRenderSourcePath {}
        check("root source-path failure occurs after focus rendering and numbering",missingCalls==2 && missing.elementID==0 && prior.elementID==1)
        let addedLater=node(4,nil,[1]),shared=node(3);var sharedCalls=0
        let sharedRevision=try Revision.root(source([3,4]),focusTree:source([3]),lineageID:"shared",identity:{$0}) {_ in
            sharedCalls += 1
            if sharedCalls==2 {shared.children.append(addedLater)}
            return render([shared])
        }
        check("focus render may mutate shared main references before table creation",sharedRevision.ids.values==[3:0,4:1] && addedLater.elementID==1)
        let nextA=node(10,"changed"),nextC=node(40,nil,[1]),nextFocus=node(10);var appendCalls=0,atFocusID:Int?
        let next=try root.appending(tree:source([10,40]),focusTree:source([10])) {_ in
            appendCalls += 1
            if appendCalls==1 {return render([nextA,nextC])}
            atFocusID=nextA.elementID;return render([nextFocus],focus:true)
        }
        check("append inheritance precedes focus renderer",atFocusID==0 && appendCalls==2)
        check("append retains previous revision and lineage",next.previousRevision===root && next.lineageRootRevision===root && next.lineageID==root.lineageID)
        check("append records main update insertion and removal",next.changes.map(\.kind)==[.update,.insert,.remove])
        check("append allocates above surviving main IDs rather than historical focus IDs",nextA.elementID==0 && nextC.elementID==1 && nextFocus.elementID==0)
        check("append preserves previous IDs and trees",b.elementID==1 && g.elementID==2 && root.tree.roots.count==2)
        check("append IDs resolve new source elements",next.element(for:1)==40)
        let childOld=node(12,nil,[0,0]),parentOld=node(11,nil,[0],[childOld]),siblingOld=node(13,nil,[1])
        let parentRevision=try Revision.root(source([11,13]),lineageID:"batch",identity:{$0}) {_ in render([parentOld,siblingOld])}
        let childNew=node(12,nil,[0,0]),parentNew=node(11,nil,[0],[childNew]),siblingNew=node(13,nil,[1])
        let childRevision=try parentRevision.appending(tree:source([11,13])) {_ in render([parentNew,siblingNew])}
        check("append retains raw sibling batches without sorting",childRevision.changes.map {$0.new!.node.identity}==[11,13,12])
        check("append inherits paired descendant IDs",childNew.elementID==childOld.elementID && siblingNew.elementID==siblingOld.elementID)
        var throwingAppendCalls=0;let retainedAfterFailure=node(10);retainedAfterFailure.elementID=999
        do {
            _=try root.appending(tree:source([10]),focusTree:source([10])) {_ in
                throwingAppendCalls += 1
                if throwingAppendCalls==1 {return render([retainedAfterFailure])}
                throw Probe.focus
            }
            fatalError("FAIL: append focus error must throw")
        } catch Probe.focus {}
        check("append focus failure retains inherited main ID",throwingAppendCalls==2 && retainedAfterFailure.elementID==0)
        let absentPath=node(10,nil,nil),afterPath=node(99,nil,[1]);var appendPathCalls=0
        do {
            _=try root.appending(tree:source([10,99]),focusTree:source([])) {_ in appendPathCalls += 1;return appendPathCalls==1 ? render([absentPath,afterPath]):render([])}
            fatalError("FAIL: append missing path must throw")
        } catch is EventStreamMissingRenderSourcePath {}
        check("append path failure preserves inheritance and skips later allocation",appendPathCalls==2 && absentPath.elementID==0 && afterPath.elementID==nil)
        let focusOnlyRoot=try Revision.root(source([]),focusTree:source([55]),lineageID:"f",identity:{$0}) {s in render(s.roots.map {node($0.node.element)})}
        focusOnlyRoot.focusRenderTree!.roots[0].elementID=1000
        let focusOnlyNew=node(55)
        let focusOnlyNext=try focusOnlyRoot.appending(tree:source([]),focusTree:source([55])) {s in s.roots.isEmpty ? render([]):render([focusOnlyNew])}
        check("append does not compare or inherit old focus-only tree",focusOnlyNext.changes.isEmpty && focusOnlyNew.elementID==1)
        let differentObject=try Revision.root(source([]),lineageID:"Exact Lineage",identity:{$0}) {_ in render([])}
        check("lineage root follows references rather than matching strings",differentObject.lineageRootRevision===differentObject && next.lineageRootRevision===root)
        let rootSnapshot=try root.renderTreeSnapshot(),focusSnapshot=try root.focusRenderTreeSnapshot()!
        check("revision snapshot uses lineage as subject",rootSnapshot.subjectID==root.lineageID && focusSnapshot.subjectID==root.lineageID && focusSnapshot.isFocus)
        let snapshotA=node(101,"alpha",[99],[node(102,"child",nil,[node(104,"grandchild")])]),snapshotB=node(103,"beta")
        let forest=render([snapshotA,snapshotB],focus:true);EventStreamRenderIDs.setInitialIDs(forest)
        snapshotA.detail="detail"
        let snapshot=try EventStreamRenderSnapshot.capture(forest,subjectID:"subject")
        check("snapshot flattens breadth-first rather than depth-first",snapshot.renders.map(\.id)==[0,3,1,2] && snapshot.renders.map(\.text)==["alpha","beta","child","grandchild"])
        check("snapshot parent indices reference flat array positions",snapshot.renders.map(\.parentIndex)==[nil,nil,0,2])
        check("snapshot does not require source paths",snapshot.renders[2].id==1)
        snapshotA.text="later";snapshotA.detail="later detail";snapshotA.elementID=900;snapshotA.children=[]
        check("snapshot is independent of later live node mutation",snapshot.renders[0].text=="alpha" && snapshot.renders[0].detailText=="detail" && snapshot.renders[0].id==0 && snapshot.renders.count==4)
        let rebuilt=snapshot.renderTree()
        check("snapshot rebuild restores shape and focus flag",rebuilt.isFocusTree && rebuilt.roots.count==2 && rebuilt.roots[0].children[0].children[0].text=="grandchild")
        check("snapshot rebuild uses numeric ID as identity and element ID",rebuilt.preorder.map(\.identity)==[0,1,2,3] && rebuilt.preorder.allSatisfy {$0.identity==$0.elementID})
        check("snapshot rebuild leaves source paths absent",rebuilt.preorder.allSatisfy {$0.sourcePath==nil})
        check("snapshot roundtrip preserves all flat fields",try EventStreamRenderSnapshot.capture(rebuilt,subjectID:snapshot.subjectID)==snapshot)
        check("empty snapshot retains subject and focus",try EventStreamRenderSnapshot.capture(render([],focus:true),subjectID:"")==EventStreamRenderSnapshot(subjectID:"",isFocus:true,renders:[]))
        let missingID=node(77);var snapshotFailed=false
        do {_=try EventStreamRenderSnapshot.capture(render([missingID]),subjectID:"s")} catch let error as EventStreamRenderSnapshotError {snapshotFailed=error.description=="Tree contains render without element ID, which is required for a snapshot."}
        check("missing numeric ID throws the missing-ID error",snapshotFailed && missingID.elementID==nil)
        a.elementID=nil;var getterFailed=false
        do {_=try root.renderTreeSnapshot()} catch is EventStreamRenderSnapshotError {getterFailed=true}
        check("revision snapshot reads current reference IDs and propagates error",getterFailed)
        a.elementID=0
        let encoded=try JSONEncoder().encode(snapshot),json=try JSONSerialization.jsonObject(with:encoded) as! [String:Any]
        check("snapshot coding uses the fixed root keys",Set(json.keys)==["subjectID","isFocus","renders"])
        let encodedNodes=json["renders"] as! [[String:Any]]
        check("snapshot coding omits nil optional fields",Set(encodedNodes[1].keys)==["id","text"] && Set(encodedNodes[2].keys)==["id","text","parentIndex"])
        check("snapshot coding retains present details",encodedNodes[0]["detailText"] as? String=="detail")
        check("snapshot Codable roundtrip preserves value equality",try JSONDecoder().decode(EventStreamRenderSnapshot.self,from:encoded)==snapshot)
        check("snapshot hash uses complete value",Set([snapshot,try JSONDecoder().decode(EventStreamRenderSnapshot.self,from:encoded)]).count==1)
        let unusual=EventStreamRenderSnapshot(subjectID:"u",isFocus:false,renders:[.init(id:8,text:"root"),.init(id:8,text:"child",detailText:"",parentIndex:0),.init(id:-3,text:"late root")])
        let unusualTree=unusual.renderTree()
        check("rebuild keeps counted-prefix behavior for interleaved roots",unusualTree.roots.count==2 && unusualTree.roots[0].children[0]===unusualTree.roots[1] && unusualTree.roots[1].text=="child")
        check("rebuild preserves duplicate numeric identities",unusualTree.preorder.map(\.identity)==[8,8,8])
        let signed=EventStreamRenderSnapshot(subjectID:"",isFocus:false,renders:[.init(id:-5,text:"",detailText:"")])
        check("signed IDs empty text and present empty details survive snapshot",try EventStreamRenderSnapshot.capture(signed.renderTree(),subjectID:"")==signed)
        let entropy=Array(UInt8(0)...UInt8(15)),date=Date(timeIntervalSince1970:1234567890.125)
        let uuid=EventStreamTimestampUUID.make(timestamp:date,randomBytes:{entropy})
        check("timestamp UUID uses exact milliseconds and entropy",uuid.uuidString=="011F71FB-04CD-7607-8809-0A0B0C0D0E0F")
        let zero=EventStreamTimestampUUID.make(timestamp:Date(timeIntervalSince1970:0),randomBytes:{Array(repeating:255,count:16)})
        check("timestamp UUID forces version7 and RFC variant bits",zero.uuidString=="00000000-0000-7FFF-BFFF-FFFFFFFFFFFF")
        let fraction=EventStreamTimestampUUID.make(timestamp:Date(timeIntervalSince1970:-0.0005),randomBytes:{entropy})
        check("fractional negative millisecond truncates to zero",fraction.uuidString.hasPrefix("00000000-0000"))
        let wide=EventStreamTimestampUUID.make(timestamp:Date(timeIntervalSince1970:281474976710.656),randomBytes:{entropy})
        check("timestamp stores low48 bits without clamping epoch",wide.uuidString.hasPrefix("00000000-0000"))
        var history=root
        for _ in 0..<300 {history=try history.appending(tree:source([])) {_ in render([])}}
        check("lineage traversal crosses deep history without artificial bound",history.lineageRootRevision===root)
        for suffix in ["parent-negative","parent-future","time-negative","time-nan","time-infinite","time-upper"] {
            let p=Process();p.executableURL = .init(fileURLWithPath:CommandLine.arguments[0]);p.arguments=["--trap-\(suffix)"]
            p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run();p.waitUntilExit()
            check("trap is retained for \(suffix)",p.terminationReason == .uncaughtSignal && p.terminationStatus != 0)
        }
        print("EVENT STREAM TREE REVISION: \(checks) checks passed")
    }
}
