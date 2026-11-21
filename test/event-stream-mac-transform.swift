import Foundation
import ApplicationServices

@MainActor final class MacBackend:EventStreamMacTransformationBackend {
    typealias Element=Int
    typealias Identity=Int
    var targets:[Int:[Int]]=[:],titles:[Int:String]=[:],bundles:[Int:String]=[:]
    var horizontal:Set<Int>=[],vertical:Set<Int>=[],queries:[String]=[]
    func identity(_ element:Int)->Int {element}
    func titleTargets(_ element:Int)->[Int] {targets[element] ?? []}
    func title(for identity:Int)->String? {queries.append("title:\(identity)");return titles[identity]}
    func hasScrollBar(_ axis:EventStreamScrollAxis,of element:Int)->Bool {
        queries.append("\(axis):\(element)");return axis == .horizontal ? horizontal.contains(element):vertical.contains(element)
    }
    func applicationBundleIdentifier(of element:Int)->String? {queries.append("bundle:\(element)");return bundles[element]}
}

@main enum MacTransformTests {
    typealias Node=EventStreamTransformedNode<Int>
    typealias Item=EventStreamCollectedItem<Int>
    typealias Result=EventStreamTreeTransformationResult<Int>
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    static func item(_ id:Int=0,children:[Item]=[],subset:EventStreamArraySubset?=nil,_ edit:(inout Node)->Void = {_ in})->Item {
        var node=Node(element:id);node.role="AXGroup";edit(&node)
        return .init(node:node,path:[id],children:children,childrenSubset:subset)
    }
    static func context(_ type:EventStreamElementContextType = .fullUIContext,catalyst:Bool=false)->EventStreamMacTransformationContext {
        .init(type:type,isCatalyst:catalyst,urlShortener:.init(configuration:.init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true)))
    }
    static func actions(_ names:[String])->[EventStreamNodeAction] {names.map {.init(name:$0,description:"description:\($0)")}}
    @MainActor static func run(_ item:Item,_ backend:MacBackend,pass:EventStreamMacTreeTransformation = .filterActions,
                               type:EventStreamElementContextType = .fullUIContext,catalyst:Bool=false)->Result {
        var ctx=context(type,catalyst:catalyst)
        return try! EventStreamMacTreeTransform.transform(item,pass:pass,context:&ctx,backend:backend) {_,_ in
            preconditionFailure("this case must not render")
        }
    }
    static func output(_ result:Result)->Item? {if case .transformed(let x)=result {return x};return nil}
    @MainActor static func filtered(_ role:String,_ names:[String],_ b:MacBackend,catalyst:Bool=false,settable:Bool=false)->[String] {
        output(run(item() {$0.role=role;$0.isValueSettable=settable;$0.actionDescriptions=actions(names)},b,catalyst:catalyst))!.node.actionDescriptions.map(\.name)
    }
    @MainActor static func main() {
        setbuf(stdout,nil)
        let b=MacBackend()
        check("native pipeline order is filter then shared0-8 then Calendar and attributed passes",EventStreamMacTreeTransformation.defaultPipeline.map(\.rawTag)==[9,0,1,2,3,4,5,6,7,8,10,11,12])
        check("all native transform tags round trip",(UInt8(0)...12).allSatisfy {EventStreamMacTreeTransformation(rawTag:$0)?.rawTag==$0})
        check("unknown native transform tag is rejected",EventStreamMacTreeTransformation(rawTag:13)==nil)
        check("full-context empty action list still returns transformed",run(item(),b).rawTag==0)
        let names=["AXShowDefaultUI","AXPress","AXShowAlternateUI","AXPress","AXShowMenu","AXScrollToVisible","custom"]
        let root=item(0,children:[item(1)],subset:.init(count:50,availableRanges:[])) {$0.title="keep";$0.actionDescriptions=actions(names)}
        let transformed=output(run(root,b))!
        check("default and alternate UI actions are removed while order and duplicates survive",transformed.node.actionDescriptions.map(\.name)==["AXPress","AXPress","AXShowMenu","AXScrollToVisible","custom"])
        check("action descriptions are preserved",transformed.node.actionDescriptions[0].description=="description:AXPress")
        check("action filter preserves node tree path and subset",transformed.node.title=="keep" && transformed.children.count==1 && transformed.path==root.path && transformed.childrenSubset==root.childrenSubset)
        check("action filter does not mutate original",root.node.actionDescriptions.count==7)
        check("unmodified nonempty list still returns transformed",run(item() {$0.actionDescriptions=actions(["AXPress"])},b).rawTag==0)
        for type in [EventStreamElementContextType.eventStreamContext,.informationalContext] {
            b.queries=[]
            check("action filtering is skipped before reads in \(type)",run(item() {$0.actionDescriptions=actions(["AXScrollUpByPage"])},b,type:type).rawTag==3 && b.queries.isEmpty)
        }
        check("action names are case and whitespace sensitive",filtered("AXGroup",["axshowdefaultui"," AXShowAlternateUI","AXShowDefaultUI "],b)==["axshowdefaultui"," AXShowAlternateUI","AXShowDefaultUI "])
        for role in ["AXMenuBar","AXMenuItem"] {check("cancel is removed from \(role)",filtered(role,["AXCancel"],b).isEmpty)}
        check("cancel is retained for menu-bar items",filtered("AXMenuBarItem",["AXCancel"],b)==["AXCancel"])
        check("Catalyst removes cancel independently of role",filtered("AXButton",["AXCancel"],b,catalyst:true).isEmpty)
        check("ordinary buttons retain cancel",filtered("AXButton",["AXCancel"],b)==["AXCancel"])
        check("pick is removed only for menu items",filtered("AXMenuItem",["AXPick"],b).isEmpty && filtered("AXMenuBar",["AXPick"],b)==["AXPick"])
        check("confirm is removed only for text-field role",filtered("AXTextField",["AXConfirm"],b).isEmpty && filtered("AXTextArea",["AXConfirm"],b)==["AXConfirm"])
        check("settable values suppress increment and decrement",filtered("AXSlider",["AXIncrement","AXDecrement","AXPress"],b,settable:true)==["AXPress"])
        check("nonsettable values retain increment and decrement",filtered("AXSlider",["AXIncrement","AXDecrement"],b)==["AXIncrement","AXDecrement"])
        b.horizontal=[0];b.queries=[]
        let scroll=["AXScrollLeftByPage","AXScrollRightByPage","AXScrollUpByPage","AXScrollDownByPage"]
        check("horizontal and vertical actions depend on their own scrollbar",filtered("AXGroup",scroll,b)==Array(scroll.prefix(2)))
        check("scrollbar reads occur once per action in action order",b.queries==["horizontal:0","horizontal:0","vertical:0","vertical:0"])
        b.horizontal=[];b.vertical=[0]
        check("vertical scrollbar preserves only vertical page actions",filtered("AXGroup",scroll,b)==Array(scroll.suffix(2)))
        b.horizontal=[0];b.vertical=[0]
        check("both scrollbars preserve all page actions",filtered("AXGroup",scroll,b)==scroll)
        b.horizontal=[];b.vertical=[]

        let prune=EventStreamMacTreeTransformation.shared(.pruneNonDescriptiveSubtrees)
        let interactive=item() {$0.role="AXButton";$0.isFocusable=true;$0.isSelectable=true;$0.actionDescriptions=actions(["AXPress"])}
        check("full context delegates ordinary descriptive pruning",run(interactive,b,pass:prune).rawTag==3)
        for type in [EventStreamElementContextType.eventStreamContext,.informationalContext] {
            check("native additional prune ignores leaf actions and interaction flags in \(type)",run(interactive,b,pass:prune,type:type).rawTag==2)
        }
        for (label,edit) in [("focused",{(n:inout Node) in n.isFocused=true}),("selected",{(n:inout Node) in n.isSelected=true}),("disclosing",{(n:inout Node) in n.isDisclosing=true})] {
            let protected=item() {$0.actionDescriptions=actions(["AXPress"]);edit(&$0)}
            check("\(label) leaf avoids additional prune then uses shared fallback",run(protected,b,pass:prune,type:.eventStreamContext).rawTag==3)
        }
        check("selected flag alone is still subject to shared fallback",run(item() {$0.isSelected=true},b,pass:prune,type:.eventStreamContext).rawTag==2)
        check("disclosable without disclosing does not protect native leaf",run(item() {$0.isDisclosable=true;$0.isFocusable=true},b,pass:prune,type:.eventStreamContext).rawTag==2)
        check("disabled state does not prevent native additional prune",run(item() {$0.isEnabled=false;$0.actionDescriptions=actions(["AXPress"])},b,pass:prune,type:.eventStreamContext).rawTag==2)
        check("partial child total is not a loaded child for additional prune",run(item(0,subset:.init(count:99,availableRanges:[])) {$0.isFocusable=true},b,pass:prune,type:.eventStreamContext).rawTag==2)
        check("loaded child prevents extra prune and shared fallback sees descendants",run(item(0,children:[item(1) {$0.isSelectable=true}]),b,pass:prune,type:.eventStreamContext).rawTag==3)
        check("placeholder protects described leaf",run(item() {$0.placeholderValue="hint"},b,pass:prune,type:.eventStreamContext).rawTag==3)
        check("image role counts as native descriptive content",run(item() {$0.role="AXImage"},b,pass:prune,type:.eventStreamContext).rawTag==3)
        check("rich transformed text alone does not protect additional prune",run(item() {$0.transformedString = .init("rich");$0.isFocusable=true},b,pass:prune,type:.eventStreamContext).rawTag==2)
        check("raw whitespace passes native guard but shared pruning still trims it",run(item() {$0.title=" "},b,pass:prune,type:.eventStreamContext).rawTag==2)

        let calendar=EventStreamMacTreeTransformation.removeElementsUnderCalendarEvents
        let event=item(0,children:[item(1) {$0.role="AXStaticText";$0.value="child"}],subset:.init(count:99,availableRanges:[7..<8])) {$0.role="AXStaticText";$0.roleDescription="Event";$0.value="parent"}
        b.bundles=[0:"com.apple.iCal"];b.queries=[]
        let calendarOut=output(run(event,b,pass:calendar))!
        check("Calendar event removes its single static-text child",calendarOut.children.isEmpty && b.queries==["bundle:0"])
        check("Calendar removal preserves parent fields path and partial descriptor",calendarOut.node.value=="parent" && calendarOut.path==event.path && calendarOut.childrenSubset==event.childrenSubset)
        check("Calendar input remains unchanged",event.children.count==1)
        for type in [EventStreamElementContextType.eventStreamContext,.informationalContext] {
            check("Calendar rule is independent of \(type) and Catalyst",output(run(event,b,pass:calendar,type:type,catalyst:true))?.children.isEmpty==true)
        }
        let wrongShapes=[item(0,children:event.children) {$0.roleDescription="Event"},item(0,children:event.children) {$0.role="AXStaticText";$0.roleDescription="event"},item(0,children:event.children) {$0.role="AXStaticText";$0.title="Event"},item(0) {$0.role="AXStaticText";$0.roleDescription="Event"},item(0,children:[item(1),item(2)]) {$0.role="AXStaticText";$0.roleDescription="Event"},item(0,children:[item(1)]) {$0.role="AXStaticText";$0.roleDescription="Event"}]
        for (index,shape) in wrongShapes.enumerated() {
            b.queries=[];check("Calendar shape guard \(index) avoids application lookup",run(shape,b,pass:calendar).rawTag==3 && b.queries.isEmpty)
        }
        for bundle in ["com.apple.ical","other",""] {
            b.bundles=[0:bundle];check("Calendar bundle matching is exact for \(bundle)",run(event,b,pass:calendar).rawTag==3)
        }
        b.bundles=[:];check("missing application leaves Calendar-shaped tree intact",run(event,b,pass:calendar).rawTag==3)

        var ctx=context();b.targets=[1:[2]];b.titles=[2:""]
        var result=try! EventStreamMacTreeTransform.transform(item(0,children:[item(1) {$0.value="label"},item(2)]),pass:.shared(.associateTitleUIElements),context:&ctx,backend:b) {_,_ in preconditionFailure("must not render")}
        check("native shared dispatch supplies backend title provider",output(result)?.children[0].node.element==1 && output(result)?.children[0].children.count==1)
        let url=URL(string:"https://example.test/path")!
        ctx=context()
        result=try! EventStreamMacTreeTransform.transform(item() {$0.role="AXLink";$0.url=url;$0.value="link"},pass:.shared(.flattenLinksIntoMarkdownText),context:&ctx,backend:b) {_,_ in preconditionFailure("must not render")}
        check("shared link dispatch mutates the owned context shortener",output(result)?.node.role=="AXStaticText" && ctx.urlShortener.urls==[url] && ctx.urlShortener.accumulated>0)
        ctx=context(.informationalContext)
        result=try! EventStreamMacTreeTransform.transform(item(0,children:[item(1) {$0.role="AXStaticText";$0.value="text"},item(2) {$0.role="AXLink";$0.url=url}]),pass:.shared(.mergeTextOnlySiblings),context:&ctx,backend:b) {_,_ in preconditionFailure("must not render")}
        check("shared sibling dispatch forwards informational type and shortener",output(result)?.children.count==1 && ctx.urlShortener.urls==[url])
        ctx=context()
        result=try! EventStreamMacTreeTransform.transform(item(0,children:[item(1)]),pass:.shared(.flattenRedundantHierarchy),context:&ctx,backend:b) {_,c in c.isChromium=true;return "same"}
        check("shared render dispatch keeps mutable native context",output(result)?.children.isEmpty==true && ctx.isChromium)
        ctx=context()
        result=try! EventStreamMacTreeTransform.transform(item(0,children:[item(1) {$0.capturedValueIsBooleanConvertible=true}]) {$0.isSelectable=true},pass:.shared(.flattenIntoSelectableAncestor),context:&ctx,backend:b,rebuild:{children,child,c in c.isWebShaped=true;children.append(child)}) {_,_ in preconditionFailure("must not render")}
        check("shared rebuild dispatch keeps mutable native context",output(result)?.children.count==1 && ctx.isWebShaped)
        for pass in [EventStreamMacTreeTransformation.retrieveAttributedTextFromTextAreas,.retrieveAttributedTextFromWebAreas] {
            do {_=try EventStreamMacTreeTransform.transform(item(),pass:pass,context:&ctx,backend:b) {_,_ in ""};check("unsupported attributed pass rejected",false)}
            catch {check("unsupported attributed pass \(pass.rawTag) rejected",error as? EventStreamMacTreeTransformationError == .unsupportedTransformation(pass))}
        }

        let ax=AXUIElementCreateApplication(getpid()),bar=AXUIElementCreateApplication(getpid()+10000)
        let h="AXHorizontalScrollBar",v="AXVerticalScrollBar"
        var reads:[String]=[],pids:[pid_t]=[]
        let native=EventStreamNativeMacTransformationBackend(read:{_,name in reads.append(name);return bar},processID:{_ in 42},bundleIdentifier:{pid in pids.append(pid);return "com.apple.iCal"})
        let source=EventStreamAXNode(ax,supportedAttributes:[h,v],attributes:[h:bar,v:NSNull()])
        check("native captured typed scrollbar avoids fresh read",native.hasScrollBar(.horizontal,of:source) && reads.isEmpty)
        check("native malformed cached scrollbar uses typed fallback",native.hasScrollBar(.vertical,of:source) && reads==[v])
        _=native.hasScrollBar(.vertical,of:source)
        check("typed fallback does not replace captured cache",reads==[v,v] && source.cachedAttribute(v) is NSNull)
        let unknown=EventStreamAXNode(ax,supportedAttributes:[],transactionAttributes:["AXRole"])
        check("native unrequested scrollbar can read beyond transaction subset",native.hasScrollBar(.horizontal,of:unknown) && reads.last==h)
        let before=reads.count
        check("native requested unsupported scrollbar skips read",!native.hasScrollBar(.horizontal,of:EventStreamAXNode(ax,supportedAttributes:[],transactionAttributes:[h])) && reads.count==before)
        check("native known unsupported scrollbar outside transaction skips read",!native.hasScrollBar(.horizontal,of:EventStreamAXNode(ax,supportedAttributes:["AXRole"])) && reads.count==before)
        check("valid captured scrollbar precedes requested unsupported gate",native.hasScrollBar(.horizontal,of:EventStreamAXNode(ax,supportedAttributes:[],attributes:[h:bar],transactionAttributes:[h])) && reads.count==before)
        let failed=EventStreamNativeMacTransformationBackend(read:{_,_ in nil})
        check("native failed scrollbar read becomes absence",!failed.hasScrollBar(.horizontal,of:EventStreamAXNode(ax,supportedAttributes:[])))
        let invalid=EventStreamNativeMacTransformationBackend(read:{_,_ in "wrong type" as NSString})
        check("native fresh wrong type is not a scrollbar",!invalid.hasScrollBar(.horizontal,of:EventStreamAXNode(ax,supportedAttributes:[])))
        check("native application lookup uses injected PID resolver",native.applicationBundleIdentifier(of:source)=="com.apple.iCal" && pids==[42])
        let noPID=EventStreamNativeMacTransformationBackend(processID:{_ in nil},bundleIdentifier:{_ in preconditionFailure("PID error must not resolve application")})
        check("PID failure skips application resolution",noPID.applicationBundleIdentifier(of:source)==nil)
        let noBundle=EventStreamNativeMacTransformationBackend(processID:{_ in 42},bundleIdentifier:{_ in nil})
        check("missing process or bundle yields nil",noBundle.applicationBundleIdentifier(of:source)==nil)
        var nativeNode=EventStreamTransformedNode(element:source);nativeNode.role="AXGroup"
        nativeNode.actionDescriptions=actions(["AXShowDefaultUI","AXScrollLeftByPage","AXScrollDownByPage"])
        let nativeItem=EventStreamCollectedItem(node:nativeNode,path:[4],children:[],childrenSubset:nil)
        ctx=context();reads=[]
        let nativeFiltered=try! EventStreamMacTreeTransform.transform(nativeItem,pass:.filterActions,context:&ctx,backend:native) {_,_ in preconditionFailure("must not render")}
        if case .transformed(let filtered)=nativeFiltered {
            check("native AX relation adapter feeds actual Mac action dispatcher",filtered.node.actionDescriptions.map(\.name)==["AXScrollLeftByPage","AXScrollDownByPage"] && reads==[v])
        } else {check("native AX relation adapter feeds actual Mac action dispatcher",false)}
        var nativeEvent=nativeNode;nativeEvent.role="AXStaticText";nativeEvent.roleDescription="Event"
        var nativeChild=EventStreamTransformedNode(element:EventStreamAXNode(bar));nativeChild.role="AXStaticText"
        let nativeEventItem=EventStreamCollectedItem(node:nativeEvent,path:[4],children:[.init(node:nativeChild,path:[4,0],children:[],childrenSubset:nil)],childrenSubset:nil)
        let nativeCalendar=try! EventStreamMacTreeTransform.transform(nativeEventItem,pass:.removeElementsUnderCalendarEvents,context:&ctx,backend:native) {_,_ in preconditionFailure("must not render")}
        if case .transformed(let cleared)=nativeCalendar {
            check("native PID bundle adapter feeds actual Calendar dispatcher",cleared.children.isEmpty && pids==[42,42])
        } else {check("native PID bundle adapter feeds actual Calendar dispatcher",false)}
        print("Event-stream Mac transforms: \(checks) checks passed")
    }
}
