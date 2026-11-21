import Foundation
import ApplicationServices

@main enum HierarchyTests {
    @MainActor static var checks=0
    @MainActor static func check(_ name:String,_ condition:@autoclosure ()->Bool) {
        let passed=condition();if !passed {fputs("FAIL: \(name)\n",stderr)}
        precondition(passed,name);checks += 1;print("PASS: \(name)")
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        let keys=EventStreamHierarchySPI.Keys(skipInspection:"skip",arrayAttributes:"arrays",truncateStrings:"truncate",maximumArrayCount:"maximum",value:"value",count:"count",incomplete:"incomplete")
        func decode(_ name:String,_ record:[String:Any],_ siblings:[String:[String:Any]]=[:],arrays:Set<String>=["AXChildren"]) -> EventStreamPartialValue {
            .decode(attribute:name,record:record,siblings:siblings,arrayAttributes:arrays,valueKey:"value",countKey:"count")
        }
        let full=decode("AXChildren",["value":[1,2],"count":2])
        check("equal array count retains complete coverage",full.array == .init(count:2,availableRanges:nil))
        check("array larger than reported count uses actual count",decode("AXChildren",["value":[1,2],"count":1]).array == full.array)
        check("requested traversal array preserves omitted tail",decode("AXChildren",["value":[1,2],"count":500]).array == .init(count:500,availableRanges:[0..<2]))
        check("empty truncated array retains empty available range",decode("AXChildren",["value":[],"count":500]).array == .init(count:500,availableRanges:[0..<0]))
        check("unrequested array does not trust larger reported count",decode("AXRows",["value":[1,2],"count":500]).array == full.array)
        check("missing array count means full array",decode("AXChildren",["value":[1,2]]).array == full.array)
        check("invalid array count means full array",decode("AXChildren",["value":[1,2],"count":"500"]).array == full.array)
        check("negative reported array count does not truncate",decode("AXChildren",["value":[1,2],"count":-1]).array == full.array)
        check("nonarray payload has no array coverage",decode("AXChildren",["value":"hello","count":500]).array==nil)
        check("missing wrapped payload is preserved as NSNull",decode("AXTitle",[:]).value is NSNull)
        check("explicit NSNull remains present",decode("AXTitle",["value":NSNull()]).value is NSNull)
        let unicode="A😀e\u{301}"
        let text=decode("AXValue",["value":unicode],["AXNumberOfCharacters":["value":100]])
        check("string coverage uses UTF16 rather than grapheme count",text.string == .init(count:100,availableRange:0..<5))
        check("ordinary string has no array metadata",text.array==nil)
        check("AXValue retains full-length string metadata",decode("AXValue",["value":unicode],["AXNumberOfCharacters":["value":5]]).string == .init(count:5,availableRange:0..<5))
        check("string total is preserved even smaller than returned value",decode("AXValue",["value":unicode],["AXNumberOfCharacters":["value":2]]).string?.count==2)
        check("numberOfCharacters is required for string coverage",decode("AXValue",["value":unicode]).string==nil)
        check("invalid numberOfCharacters leaves coverage absent",decode("AXValue",["value":unicode],["AXNumberOfCharacters":["value":"100"]]).string==nil)
        check("title never receives AXValue-only truncation metadata",decode("AXTitle",["value":unicode],["AXNumberOfCharacters":["value":100]]).string==nil)
        check("nonstring AXValue has no string metadata",decode("AXValue",["value":123],["AXNumberOfCharacters":["value":100]]).string==nil)
        let root=AXUIElementCreateApplication(getpid()),child=AXUIElementCreateApplication(getpid()+1)
        let rid=EventStreamSnapshotAXIdentity(element:root),cid=EventStreamSnapshotAXIdentity(element:child)
        func hierarchy(_ items:[EventStreamSnapshotAXIdentity:Any]) -> NSDictionary {
            Dictionary(uniqueKeysWithValues:items.map {(AnyHashable($0.key.element),$0.value)}) as NSDictionary
        }
        let source=hierarchy([rid:["AXRole":["value":"AXGroup"],"AXChildren":["value":[child],"count":500]],cid:["AXRole":["value":"AXButton"],"AXTitle":["value":"captured child"]]])
        var calls=0,seenTraversal:[String]=[],seenAttributes:Set<String>=[],seenMaximum=0
        let capture=EventStreamHierarchyCapture(keys:keys,copy:{ element,traversal,attributes,maximum in
            calls += 1;seenTraversal=traversal;seenAttributes=Set(attributes);seenMaximum=maximum
            return source
        })
        let table=capture.capture(root,traversal:["AXChildren"],attributes:["AXRole","AXTitle"],maximumArrayCount:77)
        check("native identities survive controlled hierarchy decoding",table.count==2 && table[rid]?["AXRole"]?.value as? String == "AXGroup")
        check("wrapped native references preserve child coverage",table[rid]?["AXChildren"]?.array == .init(count:500,availableRanges:[0..<1]))
        check("hierarchy call forwards traversal and value requests",seenTraversal==["AXChildren"] && seenAttributes==["AXRole","AXTitle"] && seenMaximum==77)
        check("nil hierarchy response becomes empty table",EventStreamHierarchyCapture(keys:keys,copy:{_,_,_,_ in nil}).capture(root,traversal:[],attributes:[],maximumArrayCount:1).isEmpty)
        let malformed=NSDictionary(dictionary:["invalid-key":[:]])
        check("invalid top-level identity rejects entire hierarchy",EventStreamHierarchyCapture(keys:keys,copy:{_,_,_,_ in malformed}).capture(root,traversal:[],attributes:[],maximumArrayCount:1).isEmpty)
        let bad=hierarchy([rid:["AXTitle":123],cid:["AXTitle":["value":"valid"]]])
        let badResult=EventStreamHierarchyCapture(keys:keys,copy:{_,_,_,_ in bad}).capture(root,traversal:[],attributes:[],maximumArrayCount:1)
        check("malformed node records skip node without losing other nodes",badResult[rid]==nil && badResult[cid]?["AXTitle"]?.value as? String == "valid")
        var retries=0
        let retry=EventStreamHierarchyCapture(keys:keys,copy:{element,_,_,_ in
            retries += 1
            if retries==1 {return hierarchy([rid:["incomplete":true]])}
            return source
        }).capture(root,traversal:["AXChildren"],attributes:["AXRole"],maximumArrayCount:1)
        check("incomplete node triggers actual provider retry",retries==2 && retry.count==2)
        var cycles=0
        let cycle=EventStreamHierarchyCapture(keys:keys,copy:{_,_,_,_ in cycles += 1;return hierarchy([rid:["incomplete":true]])},maximumIncompleteRetries:1).capture(root,traversal:[],attributes:[],maximumArrayCount:1)
        check("explicit nonconverging-provider budget bounds retries",cycles==2 && cycle.isEmpty)
        var transient=0
        let converged=EventStreamHierarchyCapture(keys:keys,copy:{_,_,_,_ in
            transient += 1
            return transient<4 ? hierarchy([rid:["incomplete":true]]) : source
        }).capture(root,traversal:["AXChildren"],attributes:[],maximumArrayCount:1)
        check("same identity can converge after repeated incomplete responses",transient==4 && converged.count==2)
        var deepCalls=0
        let depth=3000
        let deep=EventStreamHierarchyCapture(keys:keys,copy:{_,_,_,_ in
            deepCalls += 1
            let identity=EventStreamSnapshotAXIdentity(element:AXUIElementCreateApplication(Int32(100000+deepCalls)))
            return deepCalls<depth ? hierarchy([identity:["incomplete":true]]) : hierarchy([identity:["AXRole":["value":"AXButton"]]])
        }).capture(root,traversal:[],attributes:[],maximumArrayCount:1)
        check("3000 incomplete descendants resolve without native stack recursion",deepCalls==depth && deep.count==1 && deep.values.first?["AXRole"]?.value as? String == "AXButton")
        let mixed=hierarchy([rid:["AXRole":["value":"AXGroup"]],cid:123])
        check("invalid top-level record rejects whole capture",EventStreamHierarchyCapture(keys:keys,copy:{_,_,_,_ in mixed}).capture(root,traversal:[],attributes:[],maximumArrayCount:1).isEmpty)
        var bundleReads=0
        let reader=EventStreamNativeSnapshots()
        let builder=EventStreamNativeTransactions(snapshots:reader,hierarchy:capture,supportedAttributes:{_ in ["AXDOMClassList"]},bundleIdentifier:{_ in bundleReads += 1;return "com.kishanbagaria.jack"})
        let tx=builder.capture(root,additionalAttributes:["AXCustom","AXRole"],maximumChildCount:23)
        check("transaction builds role frequencies from every captured role",tx.roleFrequency==["AXGroup":1,"AXButton":1])
        check("transaction preserves partial attributes alongside raw snapshots",tx.partialValues[rid]?["AXChildren"]?.array?.count==500 && tx.snapshots.attributeTable[cid]?["AXTitle"] as? String == "captured child")
        check("hierarchy selection includes common20 and selected relations",EventStreamSnapshotAttributes.common.isSubset(of:seenAttributes) && Set(["AXSelectedRows","AXSelectedCells","AXSelectedChildren"]).isSubset(of:seenAttributes))
        check("transaction includes addition and app-specific DOM attribute",seenAttributes.contains("AXCustom") && seenAttributes.contains("AXDOMClassList") && bundleReads==1)
        check("transaction capability set includes traversal requests",tx.snapshots.requestedAttributes==seenAttributes.union(["AXChildren"]) && seenMaximum==23)
        var unnecessaryBundleReads=0
        let noDOM=EventStreamNativeTransactions(snapshots:reader,hierarchy:capture,supportedAttributes:{_ in []},bundleIdentifier:{_ in unnecessaryBundleReads += 1;return "com.kishanbagaria.jack"}).capture(root)
        check("unadvertised DOM attribute skips bundle lookup",unnecessaryBundleReads==0 && !noDOM.snapshots.requestedAttributes.contains("AXDOMClassList"))
        let explicitDOM=EventStreamNativeTransactions(snapshots:reader,hierarchy:capture,supportedAttributes:{_ in ["AXDOMClassList"]},bundleIdentifier:{_ in unnecessaryBundleReads += 1;return nil}).capture(root,additionalAttributes:["AXDOMClassList"])
        check("explicit DOM addition is retained without identity lookup",explicitDOM.snapshots.requestedAttributes.contains("AXDOMClassList") && unnecessaryBundleReads==0)
        let excludedDOM=EventStreamNativeTransactions(snapshots:reader,hierarchy:capture,supportedAttributes:{_ in ["AXDOMClassList"]},bundleIdentifier:{_ in "com.other.app"}).capture(root)
        check("nonallowlisted app omits automatic DOM capture",!excludedDOM.snapshots.requestedAttributes.contains("AXDOMClassList"))
        check("ambient transaction defaults absent and prefetch defaults enabled",EventStreamTreeTransactions.current==nil && EventStreamTreeTransactions.prefetchEnabled)
        EventStreamTreeTransactions.$current.withValue(tx) {
            let node=reader.node(root)
            let backend=EventStreamNativeChildren(parent:node)
            check("ambient node receives transaction table without native read",node.attribute("AXRole") as? String == "AXGroup" && node.transactionAttributes==tx.snapshots.requestedAttributes)
            check("native child count uses the reported array count",backend.count("AXChildren")==500)
            let partial=backend.partialArray("AXChildren")
            check("native child adapter preserves partial descriptor",partial?.subset == .init(count:500,availableRanges:[0..<1]))
            let collected=EventStreamChildren(backend:backend).collect(threshold:600,contextKind:0,isWebShaped:false)
            check("child collection keeps hierarchy subset descriptor",collected?.subset == .init(count:500,availableRanges:[0..<1]) && collected?.elements.count==1)
            check("child nodes inherit captured transaction and attributes",partial?.elements.first?.attribute("AXTitle") as? String == "captured child")
            check("seeded capabilities do not query unadvertised attributes",backend.supportedAttributes()==["AXRole","AXChildren"] && node.attribute("AXNeverSupported")==nil)
            EventStreamTreeTransactions.$current.withValue(nil) {
                check("nested nil scope hides inherited transaction",EventStreamTreeTransactions.current==nil)
            }
            check("nested scope restores earlier transaction",EventStreamTreeTransactions.current?.roleFrequency==tx.roleFrequency)
        }
        check("transaction does not leak outside its scope",EventStreamTreeTransactions.current==nil)
        let beforeDisabled=calls
        let disabled=EventStreamTreeTransactions.$prefetchEnabled.withValue(false) {builder.capture(root)}
        check("disabled prefetch skips hierarchy and selected capabilities",calls==beforeDisabled && disabled.partialValues.isEmpty && disabled.snapshots.requestedAttributes.isEmpty && disabled.roleFrequency.isEmpty)
        var ready=0
        await EventStreamTreeTransactions.$current.withValue(tx) {
            await Task.yield()
            check("task local survives asynchronous suspension",EventStreamTreeTransactions.current?.roleFrequency==tx.roleFrequency)
            ready = await Task {EventStreamTreeTransactions.current?.roleFrequency["AXButton"] ?? -1}.value
        }
        check("child task inherits capture transaction",ready==1)
        let detached=await EventStreamTreeTransactions.$current.withValue(tx) {
            await Task.detached {EventStreamTreeTransactions.current==nil}.value
        }
        check("detached task does not inherit capture transaction",detached)
        let explicit=EventStreamNativeSnapshots.Transaction(attributeTable:[rid:["AXTitle":"explicit" as NSString]])
        EventStreamTreeTransactions.$current.withValue(tx) {
            check("explicit snapshot transaction overrides ambient scope",reader.node(root,transaction:explicit).attribute("AXTitle") as? String == "explicit")
        }
        let receiver=EventStreamAXNode(root,supportedAttributes:["AXTitle"],attributes:["AXTitle":"receiver cache" as NSString])
        let beforeReuse=calls
        EventStreamTreeTransactions.$current.withValue(tx) {
            builder.withSubtree(receiver,additionalAttributes:["AXExtra"],maximumChildCount:999) {node in
                check("reused transaction passes original receiver and cache",node === receiver && node.attribute("AXTitle") as? String == "receiver cache")
            }
            check("reused transaction ignores new attribute and budget requests",calls==beforeReuse && EventStreamTreeTransactions.current?.snapshots.requestedAttributes==tx.snapshots.requestedAttributes)
        }
        let missing=EventStreamNativeTreeTransaction(root:child,snapshots:.init(attributeTable:[cid:[:]]),partialValues:[:],roleFrequency:[:])
        EventStreamTreeTransactions.$current.withValue(missing) {
            builder.withSubtree(receiver) {node in
                check("uncaptured receiver creates a nested fresh transaction",node !== receiver && node.attribute("AXRole") as? String == "AXGroup" && EventStreamTreeTransactions.current?.roleFrequency["AXGroup"]==1)
            }
            check("nested fresh transaction restores parent afterward",EventStreamTreeTransactions.current?.snapshots.attributeTable[rid]==nil)
            let beforeDisabledReuse=calls
            EventStreamTreeTransactions.$prefetchEnabled.withValue(false) {
                builder.withSubtree(receiver) {node in
                    check("disabled prefetch reuses active transaction even without receiver entry",node === receiver && EventStreamTreeTransactions.current?.snapshots.attributeTable[rid]==nil)
                }
            }
            check("disabled active reuse makes no hierarchy capture",calls==beforeDisabledReuse)
            enum Expected:Error {case failure}
            do {
                try builder.withSubtree(receiver) {_ in throw Expected.failure}
                preconditionFailure("expected operation failure")
            } catch Expected.failure {
                check("throwing subtree operation restores parent scope",EventStreamTreeTransactions.current?.snapshots.attributeTable[rid]==nil)
            } catch {preconditionFailure("unexpected operation error")}
        }
        let empty=EventStreamNativeTreeTransaction(root:root,snapshots:.init(attributeTable:[rid:[:]]),partialValues:[rid:[:]],roleFrequency:[:])
        EventStreamTreeTransactions.$current.withValue(empty) {
            let before=calls
            builder.withSubtree(receiver) {node in
                check("present empty prefetch entry still reuses original receiver",node === receiver)
            }
            check("empty authoritative entry prevents unnecessary recapture",calls==before)
        }
        builder.withSubtree(receiver) {node in
            check("new outer subtree operation receives captured replacement node",node !== receiver && node.attribute("AXRole") as? String == "AXGroup" && EventStreamTreeTransactions.current != nil)
        }
        check("outer subtree operation clears ambient scope after return",EventStreamTreeTransactions.current==nil)
        print("NATIVE HIERARCHY SPI: available=\(EventStreamHierarchySPI.available)")
        print("EVENT STREAM HIERARCHY: \(checks) checks passed")
    }
}
