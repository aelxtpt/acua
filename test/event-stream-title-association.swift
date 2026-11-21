import Foundation
import ApplicationServices

@MainActor final class TitleBackend:EventStreamTitleAssociationBackend {
    struct Identity:Hashable {
        let value:Int
        func hash(into h:inout Hasher) {h.combine(0)}
    }
    var targets:[Int:[Int]]=[:],aliases:[Int:Int]=[:],queries:[Int]=[]
    func identity(_ element:Int)->Identity {.init(value:aliases[element] ?? element)}
    func titleTargets(_ element:Int)->[Identity] {queries.append(element);return (targets[element] ?? []).map {identity($0)}}
}

@main enum TitleAssociationTests {
    typealias Node=EventStreamTransformedNode<Int>
    typealias Item=EventStreamCollectedItem<Int>
    typealias Result=EventStreamTreeTransformationResult<Int>
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    static func item(_ id:Int,children:[Item]=[],subset:EventStreamArraySubset?=nil,_ edit:(inout Node)->Void = {_ in})->Item {
        var node=Node(element:id);node.role="AXGroup";edit(&node)
        return .init(node:node,path:[id],children:children,childrenSubset:subset)
    }
    @MainActor static func run(_ root:Item,_ backend:TitleBackend,provider:((TitleBackend.Identity)->String?)?=nil)->Result {
        var context=0
        return try! EventStreamSharedTreeTransform.transform(root,pass:.associateTitleUIElements,context:&context,titleAssociation:backend,providerTitle:provider) {_,_ in
            preconditionFailure("title association must not render")
        }
    }
    static func output(_ r:Result)->Item? {if case .transformed(let x)=r {return x};return nil}
    @MainActor static func main() {
        setbuf(stdout,nil)
        let b=TitleBackend(),plain=item(2),label=item(1) {$0.role="AXStaticText";$0.value="  Label\n"}
        check("empty root stays unchanged",run(item(0),b).rawTag==3)
        check("no title relationships stays unchanged",run(item(0,children:[label,plain]),b).rawTag==3)
        b.targets=[1:[2]]
        let root=item(0,children:[label,plain],subset:.init(count:99,availableRanges:[50..<52])) {$0.title="parent"}
        var r=run(root,b),out=output(r)!
        check("one value field becomes target title without trimming",out.children.count==1 && out.children[0].node.title=="  Label\n")
        check("source label is removed while target identity and path survive",out.children[0].node.element==2 && out.children[0].path==[2])
        check("root metadata and partial descriptor survive sibling edits",out.node.title=="parent" && out.childrenSubset==root.childrenSubset && out.path==root.path)
        check("input snapshot stays unchanged",root.children.count==2 && root.children[1].node.title==nil)
        out=output(run(item(0,children:[plain,label]),b))!
        check("source after target uses original index until removal",out.children.count==1 && out.children[0].node.element==2 && out.children[0].node.title=="  Label\n")
        for field in [0,1,2] {
            let source=item(1) {n in if field==0 {n.value=""} else if field==1 {n.title=""} else {n.description=""}}
            check("present empty field \(field) is an eligible title",output(run(item(0,children:[source,plain]),b))?.children[0].node.title=="")
        }
        let boolLabel=item(1) {$0.value="false";$0.capturedValueIsBooleanConvertible=true}
        check("raw value is used even when stringValue is suppressed",output(run(item(0,children:[boolLabel,plain]),b))?.children[0].node.title=="false")
        let annotated=item(2,children:[item(8)],subset:.init(count:8,availableRanges:[])) {
            $0.role="AXButton";$0.description="detail";$0.value="value";$0.identifier="id";$0.url=URL(string:"https://example.test");$0.isFocusable=true
        }
        out=output(run(item(0,children:[label,annotated]),b))!
        check("copy changes only target title",out.children[0].node.description=="detail" && out.children[0].node.value=="value" && out.children[0].node.identifier=="id" && out.children[0].node.isFocusable)
        check("target subtree and subset survive title copying",out.children[0].children.map(\.node.element)==[8] && out.children[0].childrenSubset==annotated.childrenSubset)
        let richLabel=item(1,children:[item(9)]) {$0.title="own title";$0.isFocusable=true;$0.isSelectable=true;$0.isFocused=true;$0.isEnabled=false}
        check("direct copying ignores capabilities and source descendants",output(run(item(0,children:[richLabel,plain]),b))?.children.count==1)
        let titled=item(2) {$0.title="existing"}
        out=output(run(item(0,children:[label,titled]),b))!
        check("existing title falls through to grouping",out.children.map(\.node.element)==[1] && out.children[0].children[0].node.title=="existing")
        check("present empty target title blocks fallback copying",output(run(item(0,children:[label,item(2) {$0.title=""}]),b))?.children[0].node.element==1)
        var calls:[Int]=[]
        out=output(run(item(0,children:[label,titled]),b,provider:{id in calls.append(id.value);return nil}))!
        check("provided nil title overrides original existing title",out.children[0].node.element==2 && out.children[0].node.title=="  Label\n" && calls==[2])
        out=output(run(item(0,children:[label,plain]),b,provider:{_ in ""}))!
        check("provider empty title prevents copy and permits grouping",out.children[0].node.element==1 && out.children[0].children.map(\.node.element)==[2])
        let nestedLabel=item(1,children:[item(9)]) {$0.value="label"}
        check("blocked title with nonleaf source remains unchanged",run(item(0,children:[nestedLabel,titled]),b).rawTag==3)
        out=output(run(item(0,children:[item(1) {$0.value="v";$0.title=""},plain]),b,provider:{_ in preconditionFailure("ambiguous text must not query provider")}))!
        check("two present text fields including empty force grouping",out.children[0].node.element==1 && out.children[0].children.map(\.node.element)==[2])
        let noText=item(1) {$0.placeholderValue="ignored";$0.help="ignored";$0.transformedString = .init("ignored")}
        check("other descriptive fields do not become a title",output(run(item(0,children:[noText,plain]),b))?.children[0].node.element==1)
        b.targets=[1:[3,2,3,2]];b.queries=[]
        out=output(run(item(0,children:[item(1,subset:.init(count:70,availableRanges:[4..<5])),plain,item(3)]),b))!
        check("multiple targets group in relationship order after deduplication",out.children[0].children.map(\.node.element)==[3,2])
        check("moved items keep original source paths",out.children[0].children.map(\.path)==[[3],[2]])
        check("grouping preserves source partial metadata despite loaded leaf",out.children[0].childrenSubset == .init(count:70,availableRanges:[4..<5]))
        check("removed original siblings are skipped before querying their targets",b.queries==[1])
        check("hash collisions do not merge unequal target IDs",out.children[0].children.count==2)
        b.targets=[1:[4,2,3]]
        out=output(run(item(0,children:[plain,item(1),item(3),item(4),item(5)]),b))!
        check("descending index removal preserves source and unrelated sibling",out.children.map(\.node.element)==[1,5])
        check("nonmonotonic relationship order controls grouped children",out.children[0].children.map(\.node.element)==[4,2,3])
        b.targets=[1:[2,3]]
        check("one missing target cancels all grouping",run(item(0,children:[item(1),plain]),b).rawTag==3)
        check("descendant-only target is not a sibling match",run(item(0,children:[item(1),item(4,children:[plain,item(3)])]),b).rawTag==3)
        check("nonleaf source cannot use grouping path",run(item(0,children:[item(1,children:[item(9)]),plain,item(3)]),b).rawTag==3)
        b.targets=[1:[2],3:[2]]
        out=output(run(item(0,children:[label,item(3) {$0.description="later"},plain]),b))!
        check("later source may overwrite earlier title using original title absence",out.children.count==1 && out.children[0].node.title=="later")
        b.targets=[1:[2],2:[3]]
        out=output(run(item(0,children:[label,plain,item(3)]),b))!
        check("later source text eligibility uses original presentation fields",out.children.count==1 && out.children[0].node.element==2 && out.children[0].node.title=="  Label\n" && out.children[0].children.map(\.node.element)==[3])
        b.targets=[1:[2],3:[99]]
        out=output(run(item(0,children:[label,plain,item(3) {$0.title="missing"}]),b))!
        check("later failed relationship retains earlier successful edits",out.children.map(\.node.element)==[2,3] && out.children[0].node.title=="  Label\n")
        b.targets=[1:[4,2]];b.aliases=[4:2]
        out=output(run(item(0,children:[label,plain]),b))!
        check("native-equal alias targets deduplicate before single-target branch",out.children[0].node.element==2 && out.children[0].node.title=="  Label\n")
        b.aliases=[:];b.targets=[1:[1]]
        check("direct self-target follows remove-source semantics",output(run(item(0,children:[label]),b))?.children.isEmpty==true)
        b.targets=[1:[2,1]]
        var context:[String]=[]
        r=try! EventStreamSharedTreeTransform.transform(item(0,children:[item(1),plain]),pass:.associateTitleUIElements,context:&context,titleAssociation:b,rebuild:{children,target,c in
            c.append("\(target.node.element):\(target.children.count)");children.append(target)
        }) {_,_ in preconditionFailure("must not render")}
        check("grouping self-target fetch observes preceding append",context==["2:0","1:1"])
        check("self-target removal can remove the whole grouped subtree",output(r)?.children.isEmpty==true)
        b.targets=[1:[3,2]];context=[]
        r=try! EventStreamSharedTreeTransform.transform(item(0,children:[item(1),plain,item(3)]),pass:.associateTitleUIElements,context:&context,titleAssociation:b,rebuild:{children,target,c in
            c.append("\(target.node.element):\(children.count)");if target.node.element==2 {children.append(target)}
        }) {_,_ in preconditionFailure("must not render")}
        check("rebuild receives ordered targets and mutable accumulated children",context==["3:0","2:0"])
        check("rebuild controls append but original siblings are still removed",output(r)?.children[0].children.map(\.node.element)==[2])
        b.targets=[1:[2]];context=[]
        r=try! EventStreamSharedTreeTransform.transform(root,pass:.associateTitleUIElements,context:&context,titleAssociation:b,rebuild:{_,_,_ in preconditionFailure("direct copying must not rebuild")}) {_,_ in preconditionFailure("must not render")}
        check("direct title copying leaves rebuild context untouched",r.rawTag==0 && context.isEmpty)
        r=try! EventStreamSharedTreeTransform.transform(item(0),pass:.mergeSingleItemGroups,context:&context,titleAssociation:b) {_,_ in preconditionFailure("empty group must not render")}
        check("backend overload delegates other shared passes",r.rawTag==2)

        let ax=AXUIElementCreateApplication(getpid()),a=AXUIElementCreateApplication(getpid()+10000),other=AXUIElementCreateApplication(getpid()+10001)
        let attr="AXServesAsTitleForUIElements",native=EventStreamNativeTitleAssociationBackend()
        var reads=0
        let injected=EventStreamNativeTitleAssociationBackend(read:{_,name in precondition(name==attr);reads += 1;return [other] as NSArray})
        func source(_ raw:AnyObject?,supported:Set<String>=[attr],requested:Set<String>?=nil)->EventStreamAXNode {
            EventStreamAXNode(ax,supportedAttributes:supported,attributes:raw.map {[attr:$0]} ?? [:],transactionAttributes:requested)
        }
        let cached=source([a,a,other] as NSArray)
        check("native target reader preserves order and duplicates before shared dedup",native.titleTargets(cached).map(\.element).elementsEqual([a,a,other],by:CFEqual))
        check("native identity uses equality of underlying AX references",native.identity(cached)==native.identity(source(nil)) && native.identity(cached) != .init(element:a))
        check("captured empty target array suppresses fresh read",injected.titleTargets(source([] as NSArray)).isEmpty && reads==0)
        let mixed=source([a,"bad" as NSString,NSNull(),other] as NSArray)
        check("native array unwrapping discards malformed members individually",injected.titleTargets(mixed).map(\.element).elementsEqual([a,other],by:CFEqual) && reads==0)
        check("all-invalid array remains authoritative empty",injected.titleTargets(source([NSNull()] as NSArray)).isEmpty && reads==0)
        let invalid=source("invalid" as NSString)
        check("malformed captured nonarray falls back to native reader",injected.titleTargets(invalid)==[.init(element:other)] && reads==1)
        check("fallback does not overwrite captured attributes",invalid.cachedAttribute(attr) as? String == "invalid")
        _=injected.titleTargets(invalid)
        check("fallback is freshly attempted again for same invalid snapshot",reads==2)
        check("requested unsupported targets do not read",injected.titleTargets(source(nil,supported:[],requested:[attr])).isEmpty && reads==2)
        check("known unsupported targets outside a transaction do not read",injected.titleTargets(source(nil,supported:["AXRole"])).isEmpty && reads==2)
        check("unrequested targets may read outside transaction subset",injected.titleTargets(source(nil,supported:[],requested:["AXRole"]))==[.init(element:other)] && reads==3)
        check("empty unknown capabilities allow native fallback",injected.titleTargets(source(nil,supported:[]))==[.init(element:other)] && reads==4)
        check("captured valid targets precede unsupported requested gate",injected.titleTargets(source([a] as NSArray,supported:[],requested:[attr]))==[.init(element:a)] && reads==4)
        let failed=EventStreamNativeTitleAssociationBackend(read:{_,_ in nil})
        check("native read failure yields no relationships",failed.titleTargets(source(nil)).isEmpty)
        var nativeContext=0
        let sourceNode=EventStreamAXNode(ax,supportedAttributes:[attr],attributes:[attr:[a,a] as NSArray])
        let targetNode=EventStreamAXNode(a,supportedAttributes:[])
        var transformedSource=EventStreamTransformedNode(element:sourceNode);transformedSource.value="native label"
        let sourceItem=EventStreamCollectedItem(node:transformedSource,path:[4],children:[],childrenSubset:nil)
        let targetItem=EventStreamCollectedItem(node:EventStreamTransformedNode(element:targetNode),path:[5],children:[],childrenSubset:nil)
        let nativeRoot=EventStreamCollectedItem(node:EventStreamTransformedNode(element:EventStreamAXNode(other)),path:[],children:[sourceItem,targetItem],childrenSubset:nil)
        let nativeResult=try! EventStreamSharedTreeTransform.transform(nativeRoot,pass:.associateTitleUIElements,context:&nativeContext,titleAssociation:native) {_,_ in preconditionFailure("must not render")}
        if case .transformed(let result)=nativeResult {
            check("actual native cache and identity adapters feed shared title association",result.children.count==1 && CFEqual(result.children[0].node.element.element,a) && result.children[0].node.title=="native label")
        } else {check("actual native cache and identity adapters feed shared title association",false)}
        let targetID=EventStreamSnapshotAXIdentity(element:a)
        let transaction=EventStreamNativeTreeTransaction(root:ax,snapshots:.init(attributeTable:[targetID:["AXTitle":"" as NSString]],requestedAttributes:["AXTitle"]),partialValues:[:],roleFrequency:[:])
        EventStreamTreeTransactions.$current.withValue(transaction) {
            check("native title provider reads present empty title from active transaction",native.title(for:targetID)=="")
            let result=try! EventStreamSharedTreeTransform.transform(nativeRoot,pass:.associateTitleUIElements,context:&nativeContext,titleAssociation:native,providerTitle:{native.title(for:$0)}) {_,_ in preconditionFailure("must not render")}
            if case .transformed(let grouped)=result {
                check("captured title prevents copy despite absent presentation title",grouped.children.count==1 && CFEqual(grouped.children[0].node.element.element,ax) && grouped.children[0].children.count==1)
            } else {check("captured title prevents copy despite absent presentation title",false)}
        }
        let emptyTransaction=EventStreamNativeTreeTransaction(root:ax,snapshots:.init(attributeTable:[targetID:[:]],requestedAttributes:["AXTitle"]),partialValues:[:],roleFrequency:[:])
        EventStreamTreeTransactions.$current.withValue(emptyTransaction) {
            check("present empty captured table yields nil without borrowing presentation title",native.title(for:targetID)==nil)
            var titled=targetItem.node;titled.title="presentation only"
            let titledRoot=EventStreamCollectedItem(node:nativeRoot.node,path:[],children:[sourceItem,.init(node:titled,path:[5],children:[],childrenSubset:nil)],childrenSubset:nil)
            let result=try! EventStreamSharedTreeTransform.transform(titledRoot,pass:.associateTitleUIElements,context:&nativeContext,titleAssociation:native,providerTitle:{native.title(for:$0)}) {_,_ in preconditionFailure("must not render")}
            if case .transformed(let copied)=result {
                check("native provider nil permits replacing presentation-only title",copied.children.count==1 && copied.children[0].node.title=="native label")
            } else {check("native provider nil permits replacing presentation-only title",false)}
        }
        let invalidTitleTransaction=EventStreamNativeTreeTransaction(root:ax,snapshots:.init(attributeTable:[targetID:["AXTitle":NSNull()]],requestedAttributes:["AXTitle"]),partialValues:[:],roleFrequency:[:])
        EventStreamTreeTransactions.$current.withValue(invalidTitleTransaction) {
            check("invalid captured title decodes nil",native.title(for:targetID)==nil)
        }
        print("Event-stream title association: \(checks) checks passed")
    }
}
