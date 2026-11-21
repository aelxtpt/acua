import Foundation
import ApplicationServices

@MainActor private final class Backend: EventStreamSnapshotBackend {
    typealias Element=Int
    typealias Value=String
    var supported: Set<String> = [], bundle: String?, payload: [String:String] = [:], fails=false
    var namesReads=0, bundleReads=0, requests: [Set<String>] = []
    func supportedAttributes(of element:Int) -> Set<String> {namesReads += 1;return supported}
    func bundleIdentifier(of element:Int) -> String? {bundleReads += 1;return bundle}
    func values(of element:Int,for attributes:Set<String>) throws -> [String:String] {
        requests.append(attributes)
        if fails {throw NSError(domain:"fixture",code:1)}
        return payload
    }
}

@main enum EventStreamSnapshotTests {
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ result:@autoclosure () -> Bool) {
        guard result() else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        let b=Backend(),collector=EventStreamElementSnapshots(backend:b)
        check("common prefetch contract contains exactly20 attributes",EventStreamSnapshotAttributes.common.count==20)
        b.supported=["AXTitle","AXValue","AXChildren","AXCustom"]
        b.payload=["AXTitle":"before","AXValue":"value"]
        let first=collector.capture(1)
        check("capture retains all advertised attributes but requests only selected",first.supportedAttributes==b.supported && b.requests.last==["AXTitle","AXValue"])
        check("fallback snapshot retains returned values and no transaction marker",first.attributes==b.payload && first.transactionAttributes==nil)
        check("DOM identity lookup is lazy when not advertised",b.bundleReads==0)
        b.payload["AXTitle"]="after";let second=collector.capture(1)
        check("capture outside a transaction does not reuse a fallback",second.attributes["AXTitle"]=="after" && b.namesReads==2 && b.requests.count==2)
        let related:Set<String>=["AXVisibleRows","AXVisibleChildren","AXSelectedRows","AXSelectedCells","AXSelectedChildren"]
        b.supported=related;_ = collector.capture(2)
        check("all five supported visibility/selection relations are prefetched",b.requests.last==related)
        b.supported=["AXDOMClassList"];b.bundle="other.app";let batchCount=b.requests.count
        check("DOM class list is not prefetched for another app",collector.capture(3).attributes.isEmpty && b.requests.count==batchCount)
        b.bundle="com.kishanbagaria.jack";b.payload=["AXDOMClassList":"bubble"]
        check("exact listed app receives advertised DOM class list",collector.capture(3).attributes["AXDOMClassList"]=="bubble" && b.requests.last==["AXDOMClassList"])
        for bundle in ["COM.kishanbagaria.jack","com.kishanbagaria.jack.extra",""] {
            b.bundle=bundle;check("DOM app match is exact: \(bundle)",collector.capture(3).attributes.isEmpty)
        }
        b.bundle=nil;check("unknown app does not receive DOM class list",collector.capture(3).attributes.isEmpty)
        let shared=EventStreamSnapshotFallbackCache<Int,String>()
        let seeded=EventStreamSnapshotTransaction(attributeTable:[1:["AXCustom":"seed"]],requestedAttributes:["AXRole"],fallbackCache:shared)
        let reads=b.namesReads,requests=b.requests.count
        let seed=collector.capture(1,transaction:seeded)
        check("transaction entry bypasses native discovery and prefetch policy",seed.supportedAttributes==["AXCustom"] && seed.attributes==["AXCustom":"seed"] && b.namesReads==reads && b.requests.count==requests)
        check("transaction marker retains requested set independently of keys",seed.transactionAttributes==["AXRole"])
        let empty=EventStreamSnapshotTransaction<Int,String>(attributeTable:[1:[:]],requestedAttributes:[],fallbackCache:shared)
        let emptySeed=collector.capture(1,transaction:empty)
        check("present empty transaction entry remains authoritative",emptySeed.supportedAttributes.isEmpty && emptySeed.attributes.isEmpty && emptySeed.transactionAttributes==[] && b.namesReads==reads)
        b.supported=["AXTitle"];b.payload=["AXTitle":"first"]
        let transaction=EventStreamSnapshotTransaction<Int,String>(fallbackCache:shared)
        let old=collector.capture(1,transaction:transaction)
        b.supported=["AXRole"];b.payload=["AXRole":"new"]
        let before=b.namesReads;let hit=collector.capture(1,transaction:transaction)
        check("transaction fallback hit avoids discovery and preserves snapshot",hit.supportedAttributes==old.supportedAttributes && hit.attributes==old.attributes && b.namesReads==before)
        let copy=transaction
        check("transaction copies share fallback snapshots",collector.capture(1,transaction:copy).attributes==old.attributes && b.namesReads==before)
        check("explicit transaction data wins over cached fallback",collector.capture(1,transaction:seeded).attributes==["AXCustom":"seed"])
        check("explicit transaction data does not overwrite fallback cache",collector.capture(1,transaction:transaction).attributes==old.attributes)
        check("another element captures independent data",collector.capture(2,transaction:transaction).attributes==["AXRole":"new"])
        shared.clear()
        check("cache owner can clear and capture fresh attributes",collector.capture(1,transaction:transaction).supportedAttributes==["AXRole"])
        shared.clear();b.fails=true;b.supported=["AXValue"]
        let failed=collector.capture(1,transaction:transaction)
        check("batch failure retains supported attributes with empty values",failed.supportedAttributes==["AXValue"] && failed.attributes.isEmpty && failed.transactionAttributes==nil)
        b.fails=false;b.payload=["AXValue":"refetched"];let failureRequests=b.requests.count
        check("failed batch is cached rather than repeatedly queried",collector.capture(1,transaction:transaction).attributes.isEmpty && b.requests.count==failureRequests)
        shared.clear();check("explicit cache reset permits recovery",collector.capture(1,transaction:transaction).attributes["AXValue"]=="refetched")
        shared.clear();b.supported=[];let noReads=b.requests.count
        let noAttributes=collector.capture(1,transaction:transaction)
        check("empty supported set skips batch and retains empty snapshot",noAttributes.attributes.isEmpty && noAttributes.supportedAttributes.isEmpty && b.requests.count==noReads)
        b.supported=["AXValue"];let beforeEmptyHit=b.namesReads
        check("empty fallback snapshot is still a cache hit",collector.capture(1,transaction:transaction).supportedAttributes.isEmpty && b.namesReads==beforeEmptyHit)

        func errorValue(_ error:AXError) -> AnyObject {var e=error;return AXValueCreate(.axError,&e)!}
        let noValue=errorValue(.noValue),unsupported=errorValue(.attributeUnsupported),success=errorValue(.success),failure=errorValue(.cannotComplete)
        let decoded=try EventStreamNativeSnapshotBackend.decode(names:["null","missing","unsupported","success","failed","text"],response:[NSNull(),noValue,unsupported,success,failure,"á😀" as NSString])
        check("batch decoder retains NSNull marker",decoded["null"] is NSNull)
        check("batch decoder retains the three accepted AX error markers",decoded["missing"].map {CFEqual($0,noValue)}==true && decoded["unsupported"].map {CFEqual($0,unsupported)}==true && decoded["success"].map {CFEqual($0,success)}==true)
        check("other per-attribute AX errors are omitted",decoded["failed"]==nil && decoded["text"] as? String == "á😀")
        let duplicate=try EventStreamNativeSnapshotBackend.decode(names:["x","x"],response:["old" as NSString,failure])
        check("later per-field failure removes an earlier duplicate",duplicate.isEmpty)
        let replacement=try EventStreamNativeSnapshotBackend.decode(names:["x","x"],response:["old" as NSString,NSNull()])
        check("later accepted marker replaces an earlier value",replacement["x"] is NSNull)
        let extras=try EventStreamNativeSnapshotBackend.decode(names:["x"],response:["first" as NSString,"extra" as NSString])
        check("excess batch values are ignored after requested count",extras.count==1 && extras["x"] as? String == "first")
        var shortRejected=false
        do {_ = try EventStreamNativeSnapshotBackend.decode(names:["x"],response:[])} catch {shortRejected=true}
        check("short response is rejected without indexing outside array",shortRejected)
        let identity=EventStreamSnapshotAXIdentity(element:AXUIElementCreateApplication(getpid()))
        let nativeTransaction=EventStreamNativeSnapshots.Transaction(attributeTable:[identity:["AXRole":"AXTextField" as NSString,"AXValue":"seeded" as NSString]],requestedAttributes:["AXValue","AXIdentifier"])
        let native=EventStreamNativeSnapshots(),node=native.node(identity.element,transaction:nativeTransaction)
        check("native node adapter exposes seeded snapshot attributes",node.attribute("AXRole") as? String == "AXTextField" && node.cachedAttribute("AXValue") as? String == "seeded")
        check("native node carries transaction capabilities marker",node.transactionAttributes==["AXValue","AXIdentifier"])
        check("seeded node rejects requested unsupported attribute",node.attribute("AXIdentifier")==nil)
        let legacy=EventStreamAXNode(identity.element)
        check("legacy lazy nodes have no transaction marker",legacy.transactionAttributes==nil)
        print("EVENT STREAM ELEMENT SNAPSHOTS: \(checks) checks passed")
    }
}
