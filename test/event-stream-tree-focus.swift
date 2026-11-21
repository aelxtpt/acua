import Foundation
import ApplicationServices

@main enum EventStreamTreeFocusTests {
    static var checks=0
    static func check(_ label:String,_ result:@autoclosure()->Bool) {
        guard result() else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    @MainActor static func main() {
        setbuf(stdout,nil)
        typealias Tree=EventStreamCollectedTree<Int>
        typealias Item=EventStreamCollectedItem<Int>
        func node(_ id:Int,_ text:String?=nil)->EventStreamTransformedNode<Int> {
            var n=EventStreamTransformedNode(element:id);n.title=text;return n
        }
        func item(_ id:Int,_ text:String?=nil,_ children:[Item]=[])->Item {
            .init(node:node(id,text),path:[id],children:children,childrenSubset:.init(count:10,availableRanges:[0..<1]))
        }
        var calls:[Int]=[],empty=Tree(roots:[])
        let none=EventStreamTreeFocus.make(&empty,selected:{n in calls.append(n.element);return [1]},identity:{$0},recapture:{_ in fatalError()})
        check("absent independent focus prevents selection reads",none==nil && calls.isEmpty && !empty.hasCachedTable)
        check("wrapper cannot infer focus from selected items",EventStreamTreeFocus.wrap(empty,selectedItems:[item(1)])==nil)
        let focused=node(90,"independent")
        var original=Tree(roots:[item(1,"first",[item(3)]),item(2,"second")],focusedElement:focused)
        let output=EventStreamTreeFocus.make(&original,selected:{_ in [2,1,2]},identity:{$0},recapture:{_ in fatalError()})!
        check("focus becomes the sole outer root",output.roots.count==1 && output.roots[0].node.element==90 && output.focusedElement?.element==90)
        check("selected sources retain order and duplicates",output.roots[0].children.map(\.node.element)==[2,1,2])
        check("resolved nodes retain transformed presentation",output.roots[0].children.map(\.node.title)==["second","first","second"])
        check("resolved selections strip old descendants",output.roots[0].children.allSatisfy {$0.children.isEmpty})
        check("resolved selections clear old subset metadata",output.roots[0].children.allSatisfy {$0.childrenSubset==nil})
        check("focus wrapper has no subset or diagnostic source path",output.roots[0].childrenSubset==nil && output.roots[0].path.isEmpty)
        check("selected child tree has independent nil focus",output.roots[0].subtree.focusedElement==nil)
        check("output metadata starts uncached",!output.hasCachedTable && output.descendantProperties.isEmpty && output.roots[0].subtree.descendantProperties.isEmpty)
        check("native lookup owner retains input table cache",original.hasCachedTable)
        check("focus creation leaves input hierarchy and focus untouched",original.roots[0].children.count==1 && original.roots[0].childrenSubset != nil && original.focusedElement?.title=="independent")
        var duplicate=Tree(roots:[item(1,"old"),item(1,"last")],focusedElement:focused)
        let duplicateResult=EventStreamTreeFocus.make(&duplicate,selected:{_ in [1]},identity:{$0},recapture:{_ in fatalError()})!
        check("last duplicate native identity wins through tree table",duplicateResult.roots[0].children[0].node.title=="last")
        var noSelection=Tree(roots:[],focusedElement:focused)
        let nilSelection=EventStreamTreeFocus.make(&noSelection,selected:{_ in nil},identity:{$0},recapture:{_ in fatalError()})!
        check("nil selection still returns focused node",nilSelection.preorder.map(\.node.element)==[90] && !noSelection.hasCachedTable)
        let emptySelection=EventStreamTreeFocus.make(&noSelection,selected:{_ in []},identity:{$0},recapture:{_ in fatalError()})!
        check("present empty selection does not materialize a lookup table",emptySelection.preorder.count==1 && !noSelection.hasCachedTable)
        calls=[]
        let recovered=EventStreamTreeFocus.make(&original,selected:{_ in [1,99,2]},identity:{$0},recapture:{id in
            calls.append(id);return Tree(roots:[item(id,"fresh",[item(id+1000)])],focusedElement:node(-1))
        })!
        check("one missing source recaptures every selection in order",calls==[1,99,2])
        check("recovery discards earlier reused presentation",recovered.roots[0].children.allSatisfy {$0.node.title=="fresh"})
        check("recaptured subtrees are retained",recovered.roots[0].children.map {$0.children.count}==[1,1,1])
        check("recapture focus does not replace independent outer focus",recovered.focusedElement?.element==90 && recovered.roots[0].subtree.focusedElement==nil)
        calls=[]
        _ = EventStreamTreeFocus.make(&original,selected:{_ in [99,99]},identity:{$0},recapture:{id in calls.append(id);return Tree(roots:[item(id)])})
        check("duplicate missing sources are independently recaptured",calls==[99,99])

        let a=AXUIElementCreateApplication(101),b=AXUIElementCreateApplication(102)
        var events:[String]=[],countResults:[String:(AXError,Int)]=[:],values:[String:(AXError,AnyObject?)]=[:]
        let io=EventStreamNativeSelectionIO(count:{_,name in events.append("count:"+name);return countResults[name] ?? (.success,0)},value:{_,name in events.append("value:"+name);return values[name] ?? (.success,nil)})
        let selection=EventStreamNativeSelection(io:io,capture:{EventStreamAXNode($0,supportedAttributes:[])})
        func source(_ supported:Set<String>,_ attributes:[String:AnyObject]=[:],partial:[String:EventStreamPartialValue]=[:],requested:Set<String>?=nil)->EventStreamAXNode {
            .init(AXUIElementCreateApplication(100),supportedAttributes:supported,attributes:attributes,transactionAttributes:requested,
                  partialValues:partial,related:{EventStreamAXNode($0,supportedAttributes:[])},attributeReader:{_ in fatalError("must not use caching single-attribute reader")})
        }
        let rows="AXSelectedRows",cells="AXSelectedCells",children="AXSelectedChildren"
        let all:Set<String>=[rows,cells,children]
        func ids(_ nodes:[EventStreamAXNode]?)->[EventStreamSnapshotAXIdentity]? {nodes?.map {.init(element:$0.element)}}
        let aid=EventStreamSnapshotAXIdentity(element:a),bid=EventStreamSnapshotAXIdentity(element:b)
        check("unadvertised selections cause no raw IO",selection.elements(of:source([]))==nil && events.isEmpty)
        let cached=source(all,[rows:[a] as NSArray,cells:[b] as NSArray])
        check("selected rows precede cells and children",ids(selection.elements(of:cached))==[aid] && events.isEmpty)
        check("cached row selection survives requested metadata exclusion",ids(selection.elements(of:source(all,[rows:[a] as NSArray],requested:[cells])))==[aid])
        check("empty cached rows proceed to cached cells",ids(selection.elements(of:source(all,[rows:[] as NSArray,cells:[b] as NSArray])))==[bid])
        check("malformed cached rows skip count rather than fetch",ids(selection.elements(of:source(all,[rows:"bad" as NSString,cells:[b] as NSArray])))==[bid] && events.isEmpty)
        check("mixed cached selected array drops invalid members",ids(selection.elements(of:source([rows],[rows:[NSNull(),a,"bad",b] as NSArray])))==[aid,bid])
        check("positive count with all invalid members returns present empty selection",selection.elements(of:source([rows],[rows:[NSNull()] as NSArray]))?.isEmpty==true)
        let partial=EventStreamPartialValue(value:[] as NSArray,array:.init(count:7,availableRanges:[0..<0]),string:nil)
        check("partial total count can select an empty captured slice",selection.elements(of:source(all,[rows:[] as NSArray,cells:[b] as NSArray],partial:[rows:partial]))?.isEmpty==true)
        let zero=EventStreamPartialValue(value:[a] as NSArray,array:.init(count:0,availableRanges:nil),string:nil)
        check("partial count is authoritative over captured array length",ids(selection.elements(of:source(all,[rows:[a] as NSArray,cells:[b] as NSArray],partial:[rows:zero])))==[bid])
        countResults=[rows:(.cannotComplete,5),cells:(.success,1)];values=[cells:(.success,[b] as NSArray)];events=[]
        check("failed count proceeds to the next advertised candidate",ids(selection.elements(of:source(all)))==[bid] && events==["count:"+rows,"count:"+cells,"value:"+cells])
        countResults=[rows:(.success,-1),cells:(.success,1)];events=[]
        check("negative count also proceeds to the next candidate",ids(selection.elements(of:source(all)))==[bid])
        countResults=[rows:(.success,1)];values=[rows:(.cannotComplete,[a] as NSArray),cells:(.success,[b] as NSArray)];events=[]
        check("chosen value failure does not fall through to another candidate",selection.elements(of:source(all))==nil && events==["count:"+rows,"value:"+rows])
        for status in [AXError.success,.noValue,.attributeUnsupported] {
            values=[rows:(status,[a] as NSArray)];events=[]
            check("accepted value status \(status.rawValue) retains returned array",ids(selection.elements(of:source([rows])))==[aid])
        }
        values=[rows:(.success,nil)];events=[]
        check("chosen missing value remains nil without cell fallback",selection.elements(of:source(all))==nil && events==["count:"+rows,"value:"+rows])
        values=[rows:(.success,"bad" as NSString)];events=[]
        check("chosen malformed value remains nil without cell fallback",selection.elements(of:source(all))==nil && events==["count:"+rows,"value:"+rows])
        values=[rows:(.success,[b] as NSArray)];events=[]
        let malformed=source([rows],[rows:"bad" as NSString],partial:[rows:partial])
        check("positive partial count with malformed cache falls back to raw value",ids(selection.elements(of:malformed))==[bid] && events==["value:"+rows])
        check("fresh selection does not overwrite malformed captured cache",malformed.cachedAttribute(rows) as? String == "bad")
        countResults=[children:(.success,2)];values=[children:(.success,[b,a] as NSArray)];events=[]
        check("selected children is supported as final candidate",ids(selection.elements(of:source([children])))==[bid,aid] && events==["count:"+children,"value:"+children])
        let scoped=EventStreamNativeTreeTransaction(root:a,
            snapshots:.init(attributeTable:[aid:["AXTitle":"current transaction" as NSString]],requestedAttributes:["AXTitle"]),
            partialValues:[:],roleFrequency:[:])
        let staleParent=EventStreamAXNode(AXUIElementCreateApplication(100),supportedAttributes:[rows],attributes:[rows:[a] as NSArray],
            related:{_ in fatalError("selection must use current TaskLocal rather than parent's old binding")})
        EventStreamTreeTransactions.$current.withValue(scoped) {
            let current=EventStreamNativeSelection(io:io).elements(of:staleParent)
            check("decoded selected source uses current native transaction",current?.first?.cachedAttribute("AXTitle") as? String == "current transaction")
            check("decoded selected source retains current requested attributes",current?.first?.transactionAttributes==["AXTitle"])
        }
        check("selected-source transaction is released after decoding",EventStreamTreeTransactions.current==nil)
        print("EVENT STREAM TREE FOCUS: \(checks) checks passed")
    }
}
