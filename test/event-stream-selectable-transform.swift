import Foundation

@main enum SelectableTransformTests {
    typealias Node=EventStreamTransformedNode<Int>
    typealias Item=EventStreamCollectedItem<Int>
    typealias Result=EventStreamTreeTransformationResult<Int>
    static var checks=0
    static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    static func item(_ id:Int,children:[Item]=[],subset:EventStreamArraySubset?=nil,
                     _ edit:(inout Node)->Void = {_ in})->Item {
        var node=Node(element:id);node.role="AXGroup";edit(&node)
        return .init(node:node,path:[id],children:children,childrenSubset:subset)
    }
    static func run(_ item:Item)->Result {
        var context=0
        return try! EventStreamSharedTreeTransform.transform(item,pass:.flattenIntoSelectableAncestor,context:&context) {_,_ in
            preconditionFailure("selectable flatten must not invoke the renderer")
        }
    }
    static func output(_ r:Result)->Item? {if case .transformed(let x)=r {return x};return nil}
    static func main() {
        setbuf(stdout,nil)
        let text=item(1) {$0.role="AXStaticText";$0.value="  first \n";$0.title=" title ";$0.description=" desc "}
        let boolFalse=item(2) {$0.role="AXCheckBox";$0.value="false";$0.capturedValueIsBooleanConvertible=true}
        let boolTrue=item(3) {$0.role="AXSwitch";$0.value="true";$0.capturedValueIsBooleanConvertible=true;$0.isFocusable=true}
        let root=item(0,children:[text,boolFalse,boolTrue],subset:.init(count:99,availableRanges:[10..<13])) {
            $0.isSelectable=true;$0.value=" parent ";$0.title=" root ";$0.description=" root desc ";$0.isSelected=true
            $0.url=URL(string:"https://example.test");$0.identifier="identity";$0.placeholderValue="hint"
            $0.transformedString = .init("rich untouched")
        }
        let r=run(root),out=output(r)!
        check("eligible selectable ancestor returns transformed",r.rawTag==0)
        check("flattened values trim each field and join root then descendants",out.node.value=="parent\nfirst")
        check("boolean descendants do not contribute their rendered value",out.node.value?.contains("false")==false && out.node.value?.contains("true")==false)
        check("title flattening includes root and descendant titles",out.node.title=="root\ntitle")
        check("description flattening uses its own field",out.node.description=="root desc\ndesc")
        check("both false and true boolean descendants survive in source order",out.children.map(\.node.element)==[2,3])
        check("focus is recalculated from all descendants",out.node.isFocusable)
        check("own selectable selected and effective-focus flags are retained",out.node.isSelectable && out.node.isSelected && !out.node.isFocused)
        check("root path and child-subset metadata are preserved",out.path==root.path && out.childrenSubset==root.childrenSubset)
        check("retained descendants keep original paths and roles",out.children.map(\.path)==[[2],[3]] && out.children[0].node.role=="AXCheckBox")
        check("other root metadata and rich text remain intact",out.node.url==root.node.url && out.node.identifier=="identity" && out.node.placeholderValue=="hint" && out.node.transformedString?.description=="rich untouched")
        check("input tree is not mutated",root.node.value==" parent " && root.children.count==3 && !root.node.isFocusable)
        for (label,edit) in [
            ("not selectable",{(n:inout Node) in n.isSelectable=false}),
            ("focused",{(n:inout Node) in n.isFocused=true}),
            ("table role",{(n:inout Node) in n.role="AXTable"}),
            ("table row subrole",{(n:inout Node) in n.subrole="AXTableRow"})
        ] {
            let candidate=item(0,children:[text]) {$0.isSelectable=true;edit(&$0)}
            check("\(label) parent blocks flattening",run(candidate).rawTag==3)
        }
        check("AXRow role alone is allowed",output(run(item(0,children:[text]) {$0.isSelectable=true;$0.role="AXRow"}))?.node.value=="first")
        check("table-row comparison is case sensitive",run(item(0,children:[text]) {$0.isSelectable=true;$0.subrole="axtablerow"}).rawTag==0)
        for (label,edit) in [
            ("selectable",{(n:inout Node) in n.isSelectable=true}),
            ("settable value",{(n:inout Node) in n.isValueSettable=true})
        ] {
            let protected=item(9,children:[text],edit)
            check("deep \(label) descendant blocks entire operation",run(item(0,children:[item(8,children:[protected])]) {$0.isSelectable=true}).rawTag==3)
        }
        check("own settable value does not block flattening",run(item(0,children:[text]) {$0.isSelectable=true;$0.isValueSettable=true}).rawTag==0)
        let ownFocusable=output(run(item(0) {$0.isSelectable=true;$0.isFocusable=true}))!
        check("empty eligible leaf still transforms",ownFocusable.children.isEmpty)
        check("empty flattened fields become present empty strings",ownFocusable.node.value=="" && ownFocusable.node.description=="" && ownFocusable.node.title=="")
        check("own focusability alone is replaced with false",!ownFocusable.node.isFocusable)
        let focusedText=item(4) {$0.role="AXStaticText";$0.isFocusable=true;$0.isFocused=true;$0.value=" focus "}
        let focused=output(run(item(0,children:[focusedText]) {$0.isSelectable=true;$0.isEnabled=false}))!
        check("nonboolean focused descendant is removed after contributing text",focused.children.isEmpty && focused.node.value=="focus")
        check("focusable removed descendant still contributes focusability",focused.node.isFocusable && !focused.node.isEnabled)
        let nonboolean=item(4) {$0.role="AXCheckBox";$0.value="2";$0.valueTypeName="Bool"}
        check("role and value type name do not substitute for captured Bool conversion",output(run(item(0,children:[nonboolean]) {$0.isSelectable=true}))?.children.isEmpty==true)
        let converted=item(5) {$0.role="AXStaticText";$0.value="changed after capture";$0.capturedValueIsBooleanConvertible=true}
        check("captured conversion survives later value and role changes",output(run(item(0,children:[converted]) {$0.isSelectable=true}))?.children.first?.node.element==5)
        let nested=item(7,children:[boolTrue,text],subset:.init(count:40,availableRanges:[])) {
            $0.capturedValueIsBooleanConvertible=true;$0.value="false"
        }
        let tree=item(0,children:[nested]) {$0.isSelectable=true}
        let nestedOut=output(run(tree))!
        check("retained parent does not suppress separately retained descendant",nestedOut.children.map(\.node.element)==[7,3])
        check("retained item keeps its entire original subtree and partial descriptor",nestedOut.children[0].children.map(\.node.element)==[3,1] && nestedOut.children[0].childrenSubset==nested.childrenSubset)
        check("flattened text traverses each original item once",nestedOut.node.value=="first")
        var context:[Int]=[],callbackSawEmpty=true
        let rebuilt=try! EventStreamSharedTreeTransform.transform(tree,pass:.flattenIntoSelectableAncestor,context:&context,rebuild:{children,child,c in
            if c.isEmpty {callbackSawEmpty=children.isEmpty}
            c.append(child.node.element)
            if child.node.element==3 {children.append(child)}
        }) {_,_ in preconditionFailure("renderer must not be called")}
        check("rebuild callback receives retained items in preorder and shared context",context==[7,3] && callbackSawEmpty)
        check("rebuild owns appending and can discard an item",output(rebuilt)?.children.map(\.node.element)==[3])
        let blocked=try! EventStreamSharedTreeTransform.transform(item(0,children:[item(6) {$0.isSelectable=true}]) {$0.isSelectable=true},pass:.flattenIntoSelectableAncestor,context:&context,rebuild:{_,_,_ in preconditionFailure("blocked operation must not rebuild")}) {_,_ in preconditionFailure("renderer must not be called")}
        check("blocked guard leaves callback context unchanged",blocked.rawTag==3 && context==[7,3])
        let booleanRoot=output(run(item(0,children:[text]) {$0.isSelectable=true;$0.value="true";$0.capturedValueIsBooleanConvertible=true}))!
        check("own captured boolean value is excluded from flattening",booleanRoot.node.value=="first")
        check("own boolean projection remains captured after assigning new value",booleanRoot.node.stringValue==nil)
        print("Event-stream selectable ancestor: \(checks) checks passed")
    }
}
