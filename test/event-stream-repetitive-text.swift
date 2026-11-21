import Foundation

@MainActor final class RepetitiveValueBackend:EventStreamNodeBackend {
    typealias Element=Int
    var raw:AnyObject?
    func attributes(_ element:Int)->[String:AnyObject] {
        var a:[String:AnyObject]=["AXRole":"AXStaticText" as NSString];a["AXValue"]=raw;return a
    }
    func snapshot(_ element:Int)->EventStreamValueSnapshot {.init(role:"AXStaticText",value:raw,supported:[],transactionAttributes:[])}
    func freshAttribute(_ attribute:String,of element:Int)->AnyObject? {nil}
    func freshSupportedAttributes(_ element:Int)->Set<String> {[]}
    func isAttributeSettable(_ attribute:String,of element:Int)throws->Bool {false}
    func isValueSettable(_ element:Int)->Bool {false}
    func string(_ element:Int,for range:NSRange)->String? {nil}
    func format(_ date:Date,style:EventStreamValueDateStyle)->String {"date"}
    func actions(_ element:Int)throws->[String] {[]}
    func actionDescription(_ action:String,of element:Int)throws->String? {nil}
}

@main enum RepetitiveTextTests {
    typealias Node=EventStreamTransformedNode<Int>
    typealias Item=EventStreamCollectedItem<Int>
    typealias Result=EventStreamTreeTransformationResult<Int>
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    static func node(_ id:Int=0,_ edit:(inout Node)->Void = {_ in})->Node {
        var n=Node(element:id);n.role="AXStaticText";edit(&n);return n
    }
    static func item(_ n:Node,children:[Item]=[],subset:EventStreamArraySubset?=nil)->Item {
        .init(node:n,path:[n.element],children:children,childrenSubset:subset)
    }
    static func run(_ item:Item)->Result {
        var context=0
        return try! EventStreamSharedTreeTransform.transform(item,pass:.flattenRepetitiveStaticText,context:&context) {_,_ in preconditionFailure("repetitive text must not render")}
    }
    static func transformed(_ r:Result)->Item? {if case .transformed(let x)=r {return x};return nil}
    @MainActor static func main() {
        setbuf(stdout,nil)
        let b=RepetitiveValueBackend(),builder=EventStreamNodeConstruction(backend:b)
        for (label,raw,suppressed) in [("true",NSNumber(value:true),true),("false",NSNumber(value:false),true),("integer zero",NSNumber(value:0),true),("integer one",NSNumber(value:1),true),("integer two",NSNumber(value:2),false),("floating one",NSNumber(value:1.0),true),("fraction",NSNumber(value:0.5),false)] {
            b.raw=raw;let n=builder.construct(0,context:.init(kind:1))
            check("captured \(label) uses native optional Bool conversion",n.capturedValueIsBooleanConvertible==suppressed && (suppressed ? n.stringValue==nil:n.stringValue==n.value))
        }
        b.raw="1" as NSString;var n=builder.construct(0,context:.init(kind:1))
        check("text one remains textual",n.value=="1" && n.stringValue=="1" && !n.capturedValueIsBooleanConvertible)
        b.raw="true" as NSString;n=builder.construct(0,context:.init(kind:1))
        check("text true does not become boolean",n.stringValue=="true")
        b.raw=NSNull();n=builder.construct(0,context:.init(kind:1));n.value="fallback"
        check("unknown raw value keeps fallback rendered text",n.stringValue=="fallback")
        b.raw=nil;n=builder.construct(0,context:.init(kind:1));n.value="later"
        check("absent captured value keeps later textual mutation",n.stringValue=="later")
        b.raw=NSNumber(value:1);n=builder.construct(0,context:.init(kind:1));n.value="later";n.valueTypeName="string"
        check("boolean suppression survives later value/type changes",n.stringValue==nil)
        b.raw="raw" as NSString;n=builder.construct(0,context:.init(kind:1));b.raw=NSNumber(value:1)
        check("constructed conversion state is snapshot-local",n.stringValue=="raw" && builder.construct(0,context:.init(kind:1)).stringValue==nil)
        let leaf=item(node(9) {$0.title="kept"}),match=item(node(1) {$0.description="label"},children:[leaf])
        let root=item(node() {$0.description="prefix label suffix"},children:[match])
        var r=run(root)
        check("matching child description layer is flattened by substring",transformed(r)?.children.first?.node.element==9)
        check("parent fields and original source paths are retained",transformed(r)?.node.description=="prefix label suffix" && transformed(r)?.path==[0] && transformed(r)?.children.first?.path==[9])
        check("input tree remains unchanged",root.children.first?.node.element==1 && root.children.first?.children.first?.node.element==9)
        check("child whitespace is trimmed before matching",transformed(run(item(node() {$0.description="label"},children:[item(node(1) {$0.description=" \nlabel\t"},children:[leaf])])) )?.children.first?.node.element==9)
        check("root strings are not trimmed before substring search",transformed(run(item(node() {$0.description=" label "},children:[match])))?.children.first?.node.element==9)
        check("whitespace-only description does not match",run(item(node() {$0.description=" \n"},children:[item(node(1) {$0.description=" \n"})])).rawTag==3)
        check("empty description does not match",run(item(node() {$0.description="text"},children:[item(node(1) {$0.description=""})])).rawTag==3)
        check("nil parent description cannot match",run(item(node(),children:[match])).rawTag==3)
        check("title-only repetition is not flattened",run(item(node() {$0.title="label"},children:[item(node(1) {$0.title="label"})])).rawTag==3)
        check("transformed-string-only repetition is not flattened",run(item(node() {$0.transformedString="label"},children:[item(node(1) {$0.transformedString="label"})])).rawTag==3)
        let valueMatch=item(node(1) {$0.value="value"},children:[leaf])
        check("value matches corresponding parent stringValue",transformed(run(item(node() {$0.value="parent value"},children:[valueMatch])))?.children.first?.node.element==9)
        check("boolean-convertible parent does not use rendered value",run(item(node() {$0.value="value";$0.capturedValueIsBooleanConvertible=true},children:[valueMatch])).rawTag==3)
        check("description can still match a boolean-valued parent",transformed(run(item(node() {$0.description="label";$0.capturedValueIsBooleanConvertible=true},children:[match])))?.children.first?.node.element==9)
        check("child raw value participates even when its stringValue is suppressed",transformed(run(item(node() {$0.value="value"},children:[item(node(1) {$0.value="value";$0.capturedValueIsBooleanConvertible=true},children:[leaf])])) )?.children.first?.node.element==9)
        check("unmatched description does not block a matching value",transformed(run(item(node() {$0.value="value"},children:[item(node(1) {$0.description="other";$0.value="value"},children:[leaf])])))?.children.first?.node.element==9)
        check("description is not compared with parent value",run(item(node() {$0.value="label"},children:[match])).rawTag==3)
        check("value is not compared with parent description",run(item(node() {$0.description="value"},children:[valueMatch])).rawTag==3)
        check("empty child forest returns unchanged",run(item(node() {$0.value="value"})).rawTag==3)
        check("matching leaf is removed",transformed(run(item(node() {$0.description="label"},children:[item(node(1) {$0.description="label"})])))?.children.isEmpty==true)
        let nested=item(node(1) {$0.description="label"},children:[item(node(2) {$0.description="label"},children:[leaf])])
        check("whole matching rounds continue through nested layers",transformed(run(item(node() {$0.description="label"},children:[nested])))?.children.first?.node.element==9)
        let unmatched=item(node(1) {$0.description="different"},children:[match])
        check("unmatched layer is not traversed by per-item evaluator",run(item(node() {$0.description="label"},children:[unmatched])).rawTag==3)
        let right=item(node(2) {$0.description="label"},children:[item(node(20)),item(node(21))])
        r=run(item(node() {$0.description="label"},children:[match,item(node(5)),right]))
        check("right-to-left splices preserve final sibling order",transformed(r)?.children.map(\.node.element)==[9,5,20,21])
        let subset=EventStreamArraySubset(count:1000,availableRanges:[400..<401])
        r=run(item(node() {$0.description="label"},children:[item(node(1) {$0.description="label"},children:[leaf],subset:subset)],subset:subset))
        check("repetitive pass does not apply merge partial-subset gate",transformed(r)?.children.first?.node.element==9 && transformed(r)?.childrenSubset==subset)
        for (label,edit) in [("focusable",{(n:inout Node) in n.isFocusable=true}),("selectable",{(n:inout Node) in n.isSelectable=true})] {
            check("\(label) parent blocks repetitive flattening",run(item(node(0) {$0.description="label";edit(&$0)},children:[match])).rawTag==3)
            check("deep \(label) static text protects full subtree",run(item(node() {$0.description="label"},children:[item(node(1) {$0.description="label"},children:[item(node(2,edit))])])).rawTag==3)
        }
        check("focused parent without focusability still permits repetitive flattening",transformed(run(item(node() {$0.description="label";$0.isFocused=true},children:[match])))?.children.first?.node.element==9)
        check("focused-only descendant does not independently protect tree",transformed(run(item(node() {$0.description="label"},children:[item(node(1) {$0.description="label";$0.isFocused=true},children:[leaf])])))?.children.first?.node.element==9)
        let button=item(node(2) {$0.role="AXButton";$0.isEnabled=false})
        check("deep disabled button protects full tree through native interaction predicate",run(item(node() {$0.description="label"},children:[item(node(1) {$0.description="label"},children:[button])])).rawTag==3)
        check("unmatched interactive sibling protects matching layers too",run(item(node() {$0.description="label"},children:[match,button])).rawTag==3)
        check("unfocusable group can be flattened",transformed(run(item(node() {$0.description="label"},children:[item(node(1) {$0.role="AXGroup";$0.description="label"},children:[leaf])])))?.children.first?.node.element==9)
        check("text area with selection alone is not independently protected",transformed(run(item(node() {$0.description="label"},children:[item(node(1) {$0.role="AXTextArea";$0.isSelectable=true;$0.description="label"},children:[leaf])])))?.children.first?.node.element==9)
        check("Unicode substring matching preserves canonical equivalence",transformed(run(item(node() {$0.description="caf\u{e9}"},children:[item(node(1) {$0.description="e\u{301}"},children:[leaf])])))?.children.first?.node.element==9)
        check("substring matching is case sensitive",run(item(node() {$0.description="Label"},children:[match])).rawTag==3)
        var deep=leaf
        for index in (1...200).reversed() {deep=item(node(index) {$0.description="label"},children:[deep])}
        check("two hundred nested matching layers terminate without dropping leaf",transformed(run(item(node() {$0.description="label"},children:[deep])))?.children.first?.node.element==9)
        print("Event-stream repetitive text: \(checks) checks passed")
    }
}
