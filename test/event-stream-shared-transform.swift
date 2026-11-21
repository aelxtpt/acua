import Foundation

@main enum SharedTransformTests {
    typealias Node=EventStreamTransformedNode<Int>
    typealias Item=EventStreamCollectedItem<Int>
    typealias Result=EventStreamTreeTransformationResult<Int>
    static var checks=0
    static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    static func node(_ id:Int=0,_ edit:(inout Node)->Void = {_ in})->Node {
        var n=Node(element:id);n.role="AXGroup";edit(&n);return n
    }
    static func item(_ n:Node,children:[Item]=[],subset:EventStreamArraySubset?=nil)->Item {
        .init(node:n,path:[n.element],children:children,childrenSubset:subset)
    }
    static func run(_ item:Item,_ pass:EventStreamSharedTreeTransformation = .mergeSingleItemGroups)->Result {
        var context:[Int]=[]
        let result=try! EventStreamSharedTreeTransform.transform(item,pass:pass,context:&context) {n,ctx in
            precondition(pass == .flattenRedundantHierarchy,"merge/prune must not invoke renderer")
            ctx.append(n.element);return n.role
        }
        return result
    }
    static func replacement(_ r:Result)->Item? {if case .replaced(let x)=r {return x};return nil}
    static func transformed(_ r:Result)->Item? {if case .transformed(let x)=r {return x};return nil}
    static func main() {
        setbuf(stdout,nil)
        let leaf=item(node(1) {$0.title="child"}),nested=item(node(2),children:[leaf])
        check("result tag identities are stable",Result.transformed(leaf).rawTag==0 && Result.replaced(leaf).rawTag==1 && Result.removed.rawTag==2 && Result.unchanged.rawTag==3)
        var r=run(item(node(),children:[nested]))
        check("single group is replaced with entire child item",replacement(r)?.node.element==2 && replacement(r)?.children.first?.node.element==1 && replacement(r)?.path==[2])
        check("empty unprotected group is removed",run(item(node())).rawTag==2)
        check("group with two children remains unchanged",run(item(node(),children:[leaf,nested])).rawTag==3)
        check("non-group is unchanged even with one child",run(item(node() {$0.role="AXWindow"},children:[leaf])).rawTag==3)
        for (label,edit) in [("selectable",{(n:inout Node) in n.isSelectable=true}),("focused",{(n:inout Node) in n.isFocused=true}),("title",{(n:inout Node) in n.title="label"}),("placeholder",{(n:inout Node) in n.placeholderValue="hint"}),("whitespace",{(n:inout Node) in n.description=" \n"})] {
            check("\(label) group survives single-item merge",run(item(node(0,edit),children:[leaf])).rawTag==3)
        }
        check("focusable group alone can be replaced",replacement(run(item(node() {$0.isFocusable=true},children:[leaf])))?.node.element==1)
        check("disabled group can be replaced",replacement(run(item(node() {$0.isEnabled=false},children:[leaf])))?.node.element==1)
        check("group actions alone do not prevent replacement",replacement(run(item(node() {$0.actionDescriptions=[.init(name:"AXPress",description:"Press")]},children:[leaf])))?.node.element==1)
        check("parent partial subset does not block replacement",replacement(run(item(node(),children:[leaf],subset:.init(count:400,availableRanges:[10..<11]))))?.node.element==1)
        let allSubset=EventStreamArraySubset(count:1000,availableRanges:nil)
        r=run(item(node(),children:[item(node(3),subset:allSubset)]))
        check("child subset with nil ranges permits replacement regardless of count",replacement(r)?.childrenSubset==allSubset)
        check("child explicit empty ranges block replacement",run(item(node(),children:[item(node(3),subset:.init(count:0,availableRanges:[]))])).rawTag==3)
        check("child explicit complete range also blocks replacement",run(item(node(),children:[item(node(3),subset:.init(count:1,availableRanges:[0..<1]))])).rawTag==3)
        check("child partial ranges block replacement",run(item(node(),children:[item(node(3),children:[leaf],subset:.init(count:100,availableRanges:[9..<10]))])).rawTag==3)
        var context:[Int]=[]
        let root=item(node(),children:[item(node(1),children:[item(node(11)),item(node(12))]),item(node(2),children:[item(node(21))])],subset:allSubset)
        r=try! EventStreamSharedTreeTransform.transform(root,pass:.flattenRedundantHierarchy,context:&context) {n,c in c.append(n.element);return "same"}
        check("flattening renders parent then original children right to left",context==[0,2,1])
        check("flattened children preserve original left-to-right order",transformed(r)?.children.map(\.node.element)==[11,12,21])
        check("flattening retains parent identity path and subset",transformed(r)?.node.element==0 && transformed(r)?.path==[0] && transformed(r)?.childrenSubset==allSubset)
        check("flattening keeps descendant source paths for driver rebuild",transformed(r)?.children.map(\.path)==[[11],[12],[21]])
        check("flattening does not mutate input tree",root.children.map(\.node.element)==[1,2] && root.children[0].children.map(\.node.element)==[11,12])
        check("flattening does not reconsider newly inserted grandchildren",transformed(r)?.children.count==3 && context.count==3)
        context=[]
        r=try! EventStreamSharedTreeTransform.transform(root,pass:.flattenRedundantHierarchy,context:&context) {n,c in c.append(n.element);return n.element==0 ? "parent":"other"}
        check("different rendered text retains child layer",transformed(r)?.children.map(\.node.element)==[1,2])
        check("no edits still return transformed tag",r.rawTag==0)
        let partial=item(node(1),children:[leaf],subset:.init(count:100,availableRanges:[0..<1]))
        let differentRole=item(node(2) {$0.role="AXButton"},children:[leaf])
        context=[]
        r=try! EventStreamSharedTreeTransform.transform(item(node(),children:[partial,differentRole]),pass:.flattenRedundantHierarchy,context:&context) {n,c in c.append(n.element);return "same"}
        check("partial children and role mismatch skip rendering",context==[0])
        check("partial children and role mismatch retain layers",transformed(r)?.children.map(\.node.element)==[1,2])
        let wholeChild=item(node(4),children:[leaf],subset:allSubset)
        check("nil subset ranges permit flattening regardless of child count",transformed(run(item(node(),children:[wholeChild]),.flattenRedundantHierarchy))?.children.first?.node.element==1)
        let explicitEmpty=item(node(4),children:[leaf],subset:.init(count:0,availableRanges:[]))
        check("explicit empty subset ranges prevent flattening",transformed(run(item(node(),children:[explicitEmpty]),.flattenRedundantHierarchy))?.children.first?.node.element==4)
        let explicitComplete=item(node(4),children:[leaf],subset:.init(count:1,availableRanges:[0..<1]))
        check("explicit complete subset ranges prevent flattening",transformed(run(item(node(),children:[explicitComplete]),.flattenRedundantHierarchy))?.children.first?.node.element==4)
        check("empty tree still renders parent and returns transformed",transformed(run(item(node()),.flattenRedundantHierarchy))?.children.isEmpty==true)
        check("same-role leaf with equal text is removed",transformed(run(item(node(),children:[item(node(1))]),.flattenRedundantHierarchy))?.children.isEmpty==true)
        check("flattening applies beyond group roles",transformed(run(item(node() {$0.role="AXWindow"},children:[item(node(1) {$0.role="AXWindow"},children:[leaf])]),.flattenRedundantHierarchy))?.children.first?.node.element==1)
        for (label,edit) in [("selectable",{(n:inout Node) in n.isSelectable=true}),("focused",{(n:inout Node) in n.isFocused=true}),("text",{(n:inout Node) in n.value="value"}),("placeholder",{(n:inout Node) in n.placeholderValue="hint"}),("whitespace",{(n:inout Node) in n.title=" "}),("image",{(n:inout Node) in n.role="AXImage"})] {
            context=[]
            r=try! EventStreamSharedTreeTransform.transform(item(node(0,edit),children:[nested]),pass:.flattenRedundantHierarchy,context:&context) {n,c in c.append(n.element);return "same"}
            check("\(label) parent blocks flattening before renderer",r.rawTag==3 && context.isEmpty)
        }
        context=[]
        r=try! EventStreamSharedTreeTransform.transform(item(node() {$0.isFocusable=true;$0.isEnabled=false},children:[nested]),pass:.flattenRedundantHierarchy,context:&context) {n,c in c.append(n.element);return "same"}
        check("focusable disabled parent does not independently block flattening",transformed(r)?.children.first?.node.element==1 && context==[0,2])
        var count=0
        r=try! EventStreamSharedTreeTransform.transform(root,pass:.flattenRedundantHierarchy,context:&count) {_,c in c += 1;return c==1 ? "same":(c==2 ? "same":"different")}
        check("render context mutations are visible to later children",count==3 && transformed(r)?.children.map(\.node.element)==[1,21])
        context=[]
        r=try! EventStreamSharedTreeTransform.transform(item(node(),children:[item(node(4) {$0.isSelectable=true;$0.isFocused=true},children:[leaf])]),pass:.flattenRedundantHierarchy,context:&context) {_,_ in "same"}
        check("child interaction flags have no separate gate beyond rendered text",transformed(r)?.children.first?.node.element==1)
        r=try! EventStreamSharedTreeTransform.transform(item(node(),children:[nested]),pass:.flattenRedundantHierarchy,context:&context) {n,_ in n.element==0 ? "é":"e\u{301}"}
        check("rendered equality follows Swift canonical Unicode equivalence",transformed(r)?.children.first?.node.element==1)
        r=try! EventStreamSharedTreeTransform.transform(item(node(),children:[nested]),pass:.flattenRedundantHierarchy,context:&context) {n,_ in n.element==0 ? " ":"\n"}
        check("rendered comparison does not trim whitespace",transformed(r)?.children.first?.node.element==2)
        enum Failure:Error {case render}
        context=[]
        r=try! EventStreamSharedTreeTransform.transform(root,pass:.flattenRedundantHierarchy,context:&context) {n,c in c.append(n.element);if n.element==1 {throw Failure.render};return "same"}
        check("child render failure retains child and prior successful edits",transformed(r)?.children.map(\.node.element)==[1,21] && context==[0,2,1])
        check("renderer failure leaves original children intact",root.children.map(\.node.element)==[1,2])
        context=[]
        r=try! EventStreamSharedTreeTransform.transform(root,pass:.flattenRedundantHierarchy,context:&context) {n,c in c.append(n.element);if n.element==2 {throw Failure.render};return "same"}
        check("child render failure still permits later siblings",transformed(r)?.children.map(\.node.element)==[11,12,2] && context==[0,2,1])
        context=[]
        r=try! EventStreamSharedTreeTransform.transform(root,pass:.flattenRedundantHierarchy,context:&context) {n,c in c.append(n.element);throw Failure.render}
        check("parent render failure returns unchanged before children",r.rawTag==3 && context==[0])
        check("prune subtree maps to the removed result",run(item(node()),.pruneNonDescriptiveSubtrees).rawTag==2)
        check("prune disabled maps to the unchanged result",run(item(node()),.pruneEmptyDisabledElements).rawTag==3)
        for pass in EventStreamSharedTreeTransformation.allCases where ![1,2,3,4,5,6].contains(pass.rawValue) {
            do {_ = try EventStreamSharedTreeTransform.transform(root,pass:pass,context:&context) {_,_ in ""};check("unsupported \(pass) rejected",false)}
            catch {check("unsupported \(pass) rejected",error as? EventStreamTreePruningError == .unsupportedTransformation(pass))}
        }
        print("Event-stream shared transforms: \(checks) checks passed")
    }
}
