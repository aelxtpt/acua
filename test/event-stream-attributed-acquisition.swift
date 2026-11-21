import Foundation
import ApplicationServices

struct ModelMarkerRange:Equatable {let start:Int,end:Int}
@MainActor final class AttributedBackend:EventStreamAttributedTextBackend {
    typealias Element=Int
    typealias Marker=Int
    typealias MarkerRange=ModelMarkerRange
    enum Failure:Error {case read}
    var textual:String?,chrome=false,names:Set<String>=[]
    var start:Int?=1,end:Int?=2,next:Int?,range:ModelMarkerRange? = .init(start:1,end:2)
    var text:NSAttributedString?=NSAttributedString(string:"raw attributed")
    var failures:Set<String>=[],events:[String]=[],ranges:[NSRange]=[]
    func record(_ event:String) throws {events.append(event);if failures.contains(event) {throw Failure.read}}
    func textualContext(_ element:Int)->String? {events.append("textual");return textual}
    func supportsAttribute(_ name:String,of element:Int)->Bool {events.append("supports:"+name);return chrome}
    func parameterizedAttributes(_ element:Int)->Set<String> {events.append("names");return names}
    func captureElement(_ element:Int)->Int {events.append("capture");return element+100}
    func marker(_ name:String,of element:Int)->Int? {events.append(name);return name==EventStreamAttributedTextAttributes.startMarker ? start:end}
    func markerRangeForElement(_ element:Int,parameter:Int) throws -> ModelMarkerRange? {try record("rangeFor:\(element):\(parameter)");return range}
    func nextLineEnd(_ marker:Int,of element:Int) throws -> Int? {try record("probe:\(marker)");return next}
    func makeMarkerRange(start:Int,end:Int) throws -> ModelMarkerRange? {try record("make:\(start):\(end)");return range}
    func attributedString(_ range:NSRange,of element:Int) throws -> NSAttributedString? {ranges.append(range);try record("range");return text}
    func attributedString(_ range:ModelMarkerRange,of element:Int,withOptions:Bool) throws -> NSAttributedString? {try record(withOptions ? "options":"legacy");return text}
}
@MainActor struct AcquisitionMacBackend:EventStreamMacTransformationBackend {
    func identity(_ element:Int)->Int {element}
    func titleTargets(_ element:Int)->[Int] {[]}
    func title(for identity:Int)->String? {nil}
    func hasScrollBar(_ axis:EventStreamScrollAxis,of element:Int)->Bool {false}
    func applicationBundleIdentifier(of element:Int)->String? {nil}
}
final class NativeMarker:NSObject {let index:Int;init(_ index:Int) {self.index=index}}
final class NativeMarkerRange:NSObject {}

@main enum AttributedAcquisitionTests {
    typealias A=EventStreamAttributedTextAttributes
    typealias Node=EventStreamTransformedNode<Int>
    typealias Item=EventStreamCollectedItem<Int>
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)};precondition(okay,label)
        checks += 1;print("PASS: \(label)")
    }
    static func node(_ role:String="AXTextArea",_ edit:(inout Node)->Void = {_ in})->Node {
        var n=Node(element:0);n.role=role;n.value="a😀e\u{301}";edit(&n);return n
    }
    @MainActor static func acquire(_ n:Node,_ b:AttributedBackend,web:Bool=false,type:EventStreamElementContextType = .informationalContext)->NSAttributedString? {
        try! EventStreamAttributedTextAcquisition.acquire(n,pass:web ? .retrieveAttributedTextFromWebAreas:.retrieveAttributedTextFromTextAreas,type:type,backend:b)
    }
    static func context(_ type:EventStreamElementContextType = .informationalContext)->EventStreamMacTransformationContext {
        .init(type:type,urlShortener:.init(configuration:.init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true)))
    }
    @MainActor static func main() {
        setbuf(stdout,nil)
        let b=AttributedBackend()
        check("wrong text-area role returns before native reads",acquire(node("AXTextField"),b)==nil && b.events.isEmpty)
        b.textual=A.sourceCode
        check("source-code context skips all attributed acquisition",acquire(node(),b)==nil && b.events==["textual"])
        b.events=[];b.textual=nil
        check("missing raw value skips after contextual read",acquire(node() {$0.value=nil},b)==nil && b.events==["textual"])
        b.events=[]
        check("ordinary full text fetch succeeds",acquire(node(),b) === b.text)
        check("full text fallback queries parameter support before UTF16 range",b.events==["textual","names","range"] && b.ranges.last==NSRange(location:0,length:5))
        b.events=[]
        check("empty present value still requests an empty range",acquire(node() {$0.value=""},b) != nil && b.ranges.last==NSRange(location:0,length:0))
        b.events=[]
        check("raw Bool-convertible value is not gated by stringValue",acquire(node() {$0.value="false";$0.capturedValueIsBooleanConvertible=true},b) != nil && b.ranges.last?.length==5)
        b.events=[];b.names=[A.attributedMarkerRangeWithOptions]
        check("truncated value uses exact supplied range without capability query",acquire(node() {$0.truncationRange=NSRange(location:700,length:200)},b) != nil && b.events==["textual","range"] && b.ranges.last==NSRange(location:700,length:200))
        b.events=[]
        check("truncated NSNotFound remains a range sentinel for backend",acquire(node() {$0.truncationRange=NSRange(location:NSNotFound,length:8)},b) != nil && b.ranges.last==NSRange(location:NSNotFound,length:8))
        b.events=[]
        check("marker options path uses freshly captured element parameter",acquire(node(),b) != nil && b.events==["textual","names","capture","rangeFor:0:100","options"])
        b.events=[];b.range=nil
        check("missing marker range does not fall back to UTF16",acquire(node(),b)==nil && !b.events.contains("range") && !b.events.contains("options"))
        b.range = .init(start:1,end:2);b.events=[];b.failures=["rangeFor:0:100"]
        check("marker-range request error aborts without fallback",acquire(node(),b)==nil && !b.events.contains("range") && !b.events.contains("options"))
        b.events=[];b.failures=["options"]
        check("options request error aborts without legacy fallback",acquire(node(),b)==nil && !b.events.contains("legacy") && !b.events.contains("range"))
        b.events=[];b.failures=[];b.names=[];b.textual=A.sourceCode.lowercased()
        check("source-code sentinel comparison is case sensitive",acquire(node(),b) != nil)
        b.textual=nil;b.events=[];b.failures=["range"]
        check("ordinary range error returns absence",acquire(node(),b)==nil)
        b.events=[];b.failures=[]
        for type in [EventStreamElementContextType.fullUIContext,.eventStreamContext] {
            check("web acquisition only runs informational context \(type)",acquire(node("AXWebArea"),b,web:true,type:type)==nil && b.events.isEmpty)
        }
        check("non-WebArea skips before capability reads",acquire(node(),b,web:true)==nil && b.events.isEmpty)
        b.chrome=true
        check("ChromeAXNodeId support skips web markers",acquire(node("AXWebArea"),b,web:true)==nil && b.events==["supports:"+A.chromeNodeID])
        b.chrome=false;b.events=[];b.start=nil
        check("missing start marker skips end and probe",acquire(node("AXWebArea"),b,web:true)==nil && b.events==["supports:"+A.chromeNodeID,A.startMarker])
        b.start=1;b.end=nil;b.events=[]
        check("missing end marker skips probe and range construction",acquire(node("AXWebArea"),b,web:true)==nil && !b.events.contains("probe:2") && !b.events.contains("make:1:2"))
        b.end=2;b.next=3;b.events=[]
        check("present next-line-end marker skips web extraction",acquire(node("AXWebArea"),b,web:true)==nil && b.events.last=="probe:2" && !b.events.contains("make:1:2"))
        b.next=nil;b.events=[]
        check("nil next-line probe allows the full start-end range",acquire(node("AXWebArea"),b,web:true) != nil && b.events==["supports:"+A.chromeNodeID,A.startMarker,A.endMarker,"probe:2","make:1:2","names","legacy"])
        b.events=[];b.failures=["probe:2"]
        check("next-line probe errors are swallowed and extraction continues",acquire(node("AXWebArea"),b,web:true) != nil && b.events.last=="legacy")
        b.events=[];b.failures=[];b.range=nil
        check("range creation absence skips capability lookup",acquire(node("AXWebArea"),b,web:true)==nil && !b.events.contains("names"))
        b.range = .init(start:1,end:2);b.events=[];b.names=[A.attributedMarkerRangeWithOptions]
        check("web marker options chosen after creating range",acquire(node("AXWebArea"),b,web:true) != nil && b.events.suffix(2)==["names","options"])
        b.events=[];b.failures=["options"]
        check("web options failure has no legacy retry",acquire(node("AXWebArea"),b,web:true)==nil && !b.events.contains("legacy"))
        b.events=[];b.failures=[];b.text=NSAttributedString(string:"")
        check("empty attributed result is distinct from absence",acquire(node("AXWebArea"),b,web:true)?.length==0)
        do {_=try EventStreamAttributedTextAcquisition.acquire(node(),pass:.filterActions,type:.fullUIContext,backend:b);check("unsupported acquisition rejected",false)}
        catch {check("unsupported acquisition rejected",error as? EventStreamMacTreeTransformationError == .unsupportedTransformation(.filterActions))}

        b.text=NSAttributedString(string:"raw",attributes:[NSAttributedString.Key("source"):"retained"]);b.names=[];b.events=[]
        let original=Item(node:node() {$0.identifier="id";$0.truncationRange=NSRange(location:4,length:1);$0.capturedValueIsBooleanConvertible=true},path:[4],children:[.init(node:node("AXStaticText"),path:[4,0],children:[],childrenSubset:nil)],childrenSubset:.init(count:50,availableRanges:[9..<10]))
        var ctx=context(),formatCalls=0
        let formatted=try! EventStreamMacTreeTransform.transform(original,pass:.retrieveAttributedTextFromTextAreas,context:&ctx,backend:AcquisitionMacBackend(),attributed:b,format:{text,c in
            formatCalls += 1;precondition(text === b.text);c.isCatalyst=true
            return .init("formatted output")
        }) {_,_ in preconditionFailure("attributed pass must not render")}
        if case .transformed(let result)=formatted {
            check("transform uses required formatter output rather than raw text",result.node.value=="formatted output" && result.node.transformedString?.description=="formatted output" && formatCalls==1)
            check("text-area transformation retains loaded subtree and source metadata",result.children.count==1 && result.path==original.path && result.childrenSubset==original.childrenSubset && result.node.identifier=="id")
            check("captured Boolean projection and truncation remain unchanged",result.node.stringValue==nil && result.node.truncationRange==original.node.truncationRange)
            check("raw attributed object and formatting context are retained",result.node.attributedString === b.text && ctx.isCatalyst)
        } else {check("text-area conversion transformed",false)}
        var webNode=original.node;webNode.role="AXWebArea";webNode.value=nil
        let webItem=Item(node:webNode,path:original.path,children:original.children,childrenSubset:original.childrenSubset)
        ctx=context();ctx.isChromium=true
        let webResult=try! EventStreamMacTreeTransform.transform(webItem,pass:.retrieveAttributedTextFromWebAreas,context:&ctx,backend:AcquisitionMacBackend(),attributed:b,format:{_,c in c.isWebShaped=true;return .init("web")}) {_,_ in preconditionFailure("must not render")}
        if case .transformed(let result)=webResult {
            check("web transform clears only loaded children after successful formatting",result.children.isEmpty && result.path==original.path && result.childrenSubset==original.childrenSubset && result.node.value=="web")
            check("Chromium context flag alone does not replace attribute support guard",ctx.isChromium && ctx.isWebShaped)
        } else {check("web conversion transformed",false)}
        b.text=nil;formatCalls=0
        let absent=try! EventStreamMacTreeTransform.transform(original,pass:.retrieveAttributedTextFromTextAreas,context:&ctx,backend:AcquisitionMacBackend(),attributed:b,format:{_,_ in preconditionFailure("absent acquisition must not format")}) {_,_ in preconditionFailure("must not render")}
        check("absent acquisition leaves item unchanged",absent.rawTag==3)
        b.events=[]
        let delegated=try! EventStreamMacTreeTransform.transform(original,pass:.filterActions,context:&ctx,backend:AcquisitionMacBackend(),attributed:b,format:{_,_ in preconditionFailure("other pass must not format")}) {_,_ in preconditionFailure("must not render")}
        check("formatter overload delegates other Mac passes without fetching",delegated.rawTag==3 && b.events.isEmpty)

        let ax=AXUIElementCreateApplication(getpid()),start=NativeMarker(1),end=NativeMarker(2),markerRange=NativeMarkerRange()
        let rawText=NSAttributedString(string:"native attributed")
        var reads:[String]=[],requests:[String]=[],observedCFRange:CFRange?,spellCheck:Bool?,freshSupports:Set<String>=[]
        var nextRaw:AnyObject?,parameterRaw:AnyObject?=rawText,rangeForRaw:AnyObject?=markerRange
        var io=EventStreamNativeAttributedTextIO(attribute:{_,name in reads.append(name);return name==A.startMarker ? start:(name==A.endMarker ? end:nil)},parameterized:{_,name,parameter in
            requests.append(name)
            if name==A.rangeForElement {precondition(CFEqual(parameter,ax));return rangeForRaw}
            if name==A.nextLineEnd {precondition(parameter === end);return nextRaw}
            if name==A.attributedRange {
                precondition(CFGetTypeID(parameter)==AXValueGetTypeID());var range=CFRange()
                precondition(AXValueGetValue(unsafeBitCast(parameter,to:AXValue.self),.cfRange,&range));observedCFRange=range
            }
            if name==A.attributedMarkerRangeWithOptions {
                let options=parameter as! NSDictionary
                precondition(options["AXTextMarkerRange"] as AnyObject === markerRange);spellCheck=options["AXSpellCheck"] as? Bool
                precondition(options.count==2)
            }
            return parameterRaw
        },supported:{_ in freshSupports},parameterizedNames:{_ in [A.attributedMarkerRangeWithOptions]},
            isMarker:{$0 is NativeMarker},isRange:{$0 is NativeMarkerRange},makeRange:{s,e in precondition(s === start && e === end);return markerRange})
        let native=EventStreamNativeAttributedTextBackend(io:io)
        let source=EventStreamAXNode(ax,supportedAttributes:[A.startMarker,A.endMarker],attributes:[A.startMarker:start,A.endMarker:NSNull()])
        check("native valid captured marker avoids fallback",native.marker(A.startMarker,of:source) === start && reads.isEmpty)
        check("native malformed cached marker uses typed fallback",native.marker(A.endMarker,of:source) === end && reads==[A.endMarker])
        _=native.marker(A.endMarker,of:source)
        check("native typed marker fallback does not overwrite snapshot",reads==[A.endMarker,A.endMarker] && source.cachedAttribute(A.endMarker) is NSNull)
        let before=reads.count
        check("native requested unsupported marker skips read",native.marker(A.startMarker,of:EventStreamAXNode(ax,supportedAttributes:[],transactionAttributes:[A.startMarker]))==nil && reads.count==before)
        check("native unrequested marker may read outside snapshot subset",native.marker(A.startMarker,of:EventStreamAXNode(ax,supportedAttributes:[],transactionAttributes:["AXRole"])) === start)
        freshSupports=[A.chromeNodeID]
        check("native attribute support refreshes unrequested metadata",native.supportsAttribute(A.chromeNodeID,of:EventStreamAXNode(ax,supportedAttributes:[],transactionAttributes:["AXRole"])))
        check("native requested support uses authoritative snapshot metadata",!native.supportsAttribute(A.chromeNodeID,of:EventStreamAXNode(ax,supportedAttributes:[],transactionAttributes:[A.chromeNodeID])))
        check("native parameterized capabilities reach backend",native.parameterizedAttributes(source)==[A.attributedMarkerRangeWithOptions])
        let fetched=try! native.attributedString(NSRange(location:NSNotFound,length:12),of:source)
        check("native NSNotFound range converts to CFRange minus one",fetched === rawText && observedCFRange?.location == -1 && observedCFRange?.length==12)
        _=try! native.attributedString(markerRange,of:source,withOptions:true)
        check("native options preserve marker range and disable spellcheck",spellCheck==false && requests.last==A.attributedMarkerRangeWithOptions)
        _=try! native.attributedString(markerRange,of:source,withOptions:false)
        check("native legacy marker-range request uses legacy attribute",requests.last==A.attributedMarkerRange)
        nextRaw=NSNull()
        do {_=try native.nextLineEnd(end,of:source);check("native malformed probe throws",false)}
        catch {check("native malformed probe throws",true)}
        parameterRaw="wrong" as NSString
        do {_=try native.attributedString(NSRange(location:0,length:1),of:source);check("native malformed attributed value throws",false)}
        catch {check("native malformed attributed value throws",true)}
        parameterRaw=rawText;rangeForRaw=NSNull()
        do {_=try native.markerRangeForElement(source,parameter:source);check("native malformed marker range throws",false)}
        catch {check("native malformed marker range throws",true)}
        rangeForRaw=markerRange;nextRaw=nil
        let identity=EventStreamSnapshotAXIdentity(element:ax)
        let transaction=EventStreamNativeTreeTransaction(root:ax,snapshots:.init(attributeTable:[identity:[A.textualContext:"fresh snapshot" as NSString]],requestedAttributes:[A.textualContext]),partialValues:[:],roleFrequency:[:])
        EventStreamTreeTransactions.$current.withValue(transaction) {
            let fresh=native.captureElement(source)
            check("native recapture uses active authoritative snapshot transaction",fresh !== source && CFEqual(fresh.element,source.element) && fresh.cachedAttribute(A.textualContext) as? String == "fresh snapshot")
            var n=EventStreamTransformedNode(element:source);n.role="AXTextArea";n.value="value"
            let result=try! EventStreamAttributedTextAcquisition.acquire(n,pass:.retrieveAttributedTextFromTextAreas,type:.eventStreamContext,backend:native)
            check("actual native options adapter feeds text-area acquisition",result === rawText && requests.suffix(2)==[A.rangeForElement,A.attributedMarkerRangeWithOptions])
        }
        io.parameterized={_,name,_ in if name==A.nextLineEnd {throw AttributedBackend.Failure.read};return rawText}
        io.parameterizedNames={_ in []}
        let nativeProbeError=EventStreamNativeAttributedTextBackend(io:io)
        var nativeWeb=EventStreamTransformedNode(element:source);nativeWeb.role="AXWebArea"
        check("actual native probe exception still permits legacy web extraction",try! EventStreamAttributedTextAcquisition.acquire(nativeWeb,pass:.retrieveAttributedTextFromWebAreas,type:.informationalContext,backend:nativeProbeError) === rawText)
        check("native marker SPI rejects ordinary CF objects",!EventStreamTextMarkerSPI.isMarker(NSNull()) && !EventStreamTextMarkerSPI.isRange("text" as NSString))
        print("NOTE: native text-marker SPI available=\(EventStreamTextMarkerSPI.available)")
        print("Event-stream attributed acquisition: \(checks) checks passed")
    }
}
