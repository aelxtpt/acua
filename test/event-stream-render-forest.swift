import Foundation
import ApplicationServices

@main enum EventStreamRenderForestTests {
    static var checks=0
    static func check(_ label:String,_ result:@autoclosure()->Bool) {
        guard result() else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    enum Expected:Error {case stop}
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        typealias Item=EventStreamCollectedItem<Int>
        typealias Tree=EventStreamCollectedTree<Int>
        func node(_ id:Int,_ text:String)->EventStreamTransformedNode<Int> {
            var n=EventStreamTransformedNode(element:id);n.value=text;return n
        }
        func item(_ id:Int,_ text:String,_ children:[Item]=[],_ subset:EventStreamArraySubset?=nil)->Item {
            .init(node:node(id,text),path:[999,id],children:children,childrenSubset:subset)
        }
        var visited:[Int]=[],identities:[Int]=[]
        func build(_ tree:Tree)->EventStreamRenderedTree<Int> {
            EventStreamRenderForest.build(tree,context:&visited,identity:{identities.append($0);return $0},describe:{n,log in log.append(n.element);return n.value ?? ""})
        }
        let source=Tree(roots:[item(0,"",[
            item(1,"",[item(2,"A",[],.init(count:8,availableRanges:[2..<4]))]),
            item(3,"B"),item(5,"P",[item(6,"",[item(7,"C")])])
        ],.init(count:99,availableRanges:[0..<1])),item(8,"D")])
        let rendered=build(source)
        check("every source node is described in preorder",visited==[0,1,2,3,5,6,7,8])
        check("empty roots promote descendants in source order",rendered.roots.map(\.identity)==[2,3,5,8])
        check("empty nested parent promotes to nearest rendered ancestor",rendered.roots[2].children.map(\.identity)==[7])
        check("rendered preorder retains promoted child order",rendered.preorder.map(\.identity)==[2,3,5,7,8])
        check("omitted nodes never obtain render identities",identities==[2,3,5,7,8])
        check("promoted root retains full source traversal path",rendered.roots[0].sourcePath==[0,0,0])
        check("promoted nested child retains omitted ancestor positions",rendered.roots[2].children[0].sourcePath==[0,2,0,0])
        check("retained root path uses current array position",rendered.roots[3].sourcePath==[1])
        check("diagnostic capture paths are never substituted",rendered.preorder.allSatisfy {$0.sourcePath?.first != 999})
        check("omitted parent's subset details do not transfer to children",rendered.roots[0].detail=="(showing 2-4 of 8 items)" && rendered.roots[1].detail==nil)
        check("numeric published IDs remain absent before revision ownership",rendered.preorder.allSatisfy {$0.elementID==nil})
        check("multiple source roots are not a focus tree",!rendered.isFocusTree)
        check("unassigned forest serializes without invented IDs",rendered.lines()==["A (showing 2-4 of 8 items)","B","P","\tC","D"])
        check("detail option applies to every rendered node",rendered.lines(options:.withoutDetailText)==["A","B","P","\tC","D"])
        rendered.roots[0].elementID=0;rendered.roots[2].children[0].elementID = -2
        check("published zero and negative IDs use existing line semantics",rendered.lines()[0]=="0 A (showing 2-4 of 8 items)" && rendered.lines()[3]=="\t-2 C")
        check("ID option suppresses assigned IDs without losing paths",rendered.lines(options:.withoutElementID)[3]=="\tC" && rendered.roots[0].sourcePath==[0,0,0])
        check("custom indentation follows rendered depth",rendered.lines(indent:"·")[3]=="·-2 C")
        let shared=rendered;shared.roots[1].text="shared"
        check("render-node references are shared across tree copies",rendered.roots[1].text=="shared" && shared.roots[1] === rendered.roots[1])
        check("render mutations do not edit source node values",source.roots[0].children[1].node.value=="B")

        check("absent subset has no detail",EventStreamRenderForest.subsetDescription(nil)==nil)
        check("full subset with nil ranges has no detail",EventStreamRenderForest.subsetDescription(.init(count:12,availableRanges:nil))==nil)
        check("present empty range list retains showing text",EventStreamRenderForest.subsetDescription(.init(count:12,availableRanges:[]))=="(showing  of 12 items)")
        check("half-open bounds are displayed without subtraction",EventStreamRenderForest.subsetDescription(.init(count:100,availableRanges:[0..<5]))=="(showing 0-5 of 100 items)")
        check("range order and duplicate ranges remain literal",EventStreamRenderForest.subsetDescription(.init(count:100,availableRanges:[8..<10,0..<2,8..<10]))=="(showing 8-10, 0-2, 8-10 of 100 items)")
        check("negative ranges and counts are not clamped",EventStreamRenderForest.subsetDescription(.init(count:-4,availableRanges:[(-2)..<0]))=="(showing -2-0 of -4 items)")
        check("empty range is still displayed",EventStreamRenderForest.subsetDescription(.init(count:0,availableRanges:[2..<2]))=="(showing 2-2 of 0 items)")
        check("maximum range endpoint needs no overflowing arithmetic",EventStreamRenderForest.subsetDescription(.init(count:Int.max,availableRanges:[(Int.max-1)..<Int.max]))=="(showing \(Int.max-1)-\(Int.max) of \(Int.max) items)")
        visited=[];identities=[]
        let none=build(.init(roots:[],focusedElement:node(1,"focus")))
        check("empty source forest performs no description or identity reads",none.roots.isEmpty && !none.isFocusTree && visited.isEmpty && identities.isEmpty)
        visited=[];identities=[]
        let focused=build(.init(roots:[item(0,"",[item(1,"A"),item(2,"B")])],focusedElement:node(0,"different presentation")))
        check("focus flag uses source root even when omitted",focused.isFocusTree && focused.roots.count==2)
        check("focus equality reads identities after mapping completes",identities==[1,2,0,0])
        visited=[];identities=[]
        let allEmpty=build(.init(roots:[item(0,"")],focusedElement:node(0,"focus")))
        check("focus flag can survive an empty rendered forest",allEmpty.isFocusTree && allEmpty.roots.isEmpty && identities==[0,0])
        visited=[];identities=[]
        let unfocused=build(.init(roots:[item(1,"one")]))
        check("single source root reads its identity even without focus",!unfocused.isFocusTree && identities==[1,1])
        visited=[];identities=[]
        let mismatch=build(.init(roots:[item(1,"one")],focusedElement:node(3,"focus")))
        check("different focused identity prevents focus flag",!mismatch.isFocusTree && identities==[1,1,3])
        visited=[];identities=[]
        let multi=build(.init(roots:[item(1,"one"),item(2,"two")],focusedElement:node(1,"focus")))
        check("multiple source roots skip focus identity comparison",!multi.isFocusTree && identities==[1,2])
        visited=[];identities=[]
        let duplicates=build(.init(roots:[item(9,"first"),item(9,"second")]))
        check("duplicate identities do not deduplicate render nodes",duplicates.roots.count==2 && duplicates.roots[0] !== duplicates.roots[1])
        check("duplicate identities keep independent source paths",duplicates.roots.map(\.sourcePath)==[[0],[1]])
        var unit=0
        let optionalID:EventStreamRenderedTree<Int?>=EventStreamRenderForest.build(.init(roots:[item(1,"one")],focusedElement:node(2,"other")),context:&unit,identity:{_ in nil},describe:{n,_ in n.value!})
        check("optional nil identity is a valid identity rather than omitted node",optionalID.roots.count==1 && optionalID.roots[0].identity==nil && optionalID.isFocusTree)
        visited=[];identities=[]
        let whitespace=build(.init(roots:[item(1," "),item(2,"\n")]))
        check("whitespace and newline descriptions are not trimmed",whitespace.roots.map(\.text)==[" ","\n"])
        var effects:[Int]=[],idEffects:[Int]=[],caught=false
        do {
            _ = try EventStreamRenderForest.build(Tree(roots:[item(1,"one",[item(2,"fail"),item(3,"never")])],focusedElement:node(1,"focus")),context:&effects,
                identity:{idEffects.append($0);return $0},describe:{n,log in log.append(n.element);if n.element==2 {throw Expected.stop};return n.value!})
        } catch Expected.stop {caught=true}
        check("description errors propagate with prior context effects",caught && effects==[1,2])
        check("failed mapping skips later siblings and focus comparison",idEffects==[1])
        var deep=item(500,"leaf")
        for id in (0..<300).reversed() {deep=item(id,"",[deep])}
        visited=[];identities=[]
        let promoted=build(.init(roots:[deep]))
        check("deep empty ancestry is traversed without a renderer depth clamp",promoted.roots.count==1 && promoted.roots[0].sourcePath?.count==301 && visited.count==301)

        func nativeNode(_ pid:pid_t,_ role:String,_ description:String?=nil)->EventStreamTransformedNode<EventStreamAXNode> {
            let source=EventStreamAXNode(AXUIElementCreateApplication(pid),supportedAttributes:[],attributeReader:{_ in fatalError("render must not fetch attributes")})
            var n=EventStreamTransformedNode(element:source);n.role=role;n.roleDescription=description;return n
        }
        let rejected=URL(string:"data:text/plain,omitted")!,url=URL(string:"https://www.example.test/a")!
        var parent=nativeNode(500,"AXCustom");parent.url=rejected
        var child=nativeNode(501,"AXLink","link");child.url=url
        let nativeItem=EventStreamCollectedItem(node:parent,path:[77],children:[.init(node:child,path:[88],children:[],childrenSubset:nil)],childrenSubset:nil)
        var context=EventStreamMacTransformationContext(type:.informationalContext,urlShortener:.init(configuration:.init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true)))
        let native=EventStreamNativeRenderForest.build(.init(roots:[nativeItem]),context:&context)
        check("native empty description promotes its actual child",native.roots.count==1 && native.roots[0].text=="link example.test/a" && native.roots[0].sourcePath==[0,0])
        check("omitted native node still records URL discovery",context.urlShortener.urls==[rejected,url] && context.urlShortener.accumulated=="example.test/a".count)
        let equivalent=nativeNode(501,"AXOther")
        let nativeFocus=EventStreamNativeRenderForest.build(.init(roots:[.init(node:child,path:[],children:[],childrenSubset:nil)],focusedElement:equivalent),context:&context)
        check("native focus equality uses CF identity rather than wrapper reference",nativeFocus.isFocusTree && child.element !== equivalent.element)
        print("EVENT STREAM RENDER FOREST: \(checks) checks passed")
    }
}
