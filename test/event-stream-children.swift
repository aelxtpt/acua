import Foundation
import CoreGraphics

@MainActor private final class Backend: EventStreamChildrenBackend {
    typealias Element = Int
    var counts: [String:Int] = [:], supported = Set<String>()
    var partial: [String:EventStreamChildArray<Int>] = [:], cached: [String:[Int]] = [:], arrays: [String:[Int]] = [:]
    var parentFrame: CGRect?, frames: [Int:CGRect] = [:], calls: [String] = []
    var equivalence: (Int,Int) -> Bool = { $0 == $1 }
    var hashing: (Int) -> Int = { $0 }, comparisons = 0
    func count(_ key: String) -> Int? { calls.append("count:"+key);return counts[key] }
    func supportedAttributes() -> Set<String> { calls.append("supported");return supported }
    func partialArray(_ key: String) -> EventStreamChildArray<Int>? { calls.append("partial:"+key);return partial[key] }
    func cachedArray(_ key: String) -> [Int]? { calls.append("cached:"+key);return cached[key] }
    func array(_ key: String) -> [Int]? { calls.append("array:"+key);return arrays[key] }
    func frame() -> CGRect? { calls.append("frame");return parentFrame }
    func uncachedFrame(_ element: Int) -> CGRect? { calls.append("frame:\(element)");return frames[element] }
    func equal(_ lhs: Int, _ rhs: Int) -> Bool { comparisons += 1;return equivalence(lhs,rhs) }
    func hash(_ element: Int) -> Int { hashing(element) }
}

@main enum EventStreamChildrenTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ name: String, _ result: @autoclosure () -> Bool) {
        guard result() else { fatalError("FAIL: \(name)") };checks += 1;print("PASS: \(name)")
    }
    @MainActor static func main() {
        setbuf(stdout,nil)
        let b = Backend(), reader = EventStreamChildren(backend:b)
        func collect(_ threshold: Int = 100, _ context: UInt8 = 1, _ web: Bool = false, _ clip: CGRect? = nil) -> EventStreamChildArray<Int>? {
            reader.collect(threshold:threshold,contextKind:context,isWebShaped:web,clippingFrame:clip)
        }
        for count in [Int?.none,0,-1] {
            b.counts = count.map { ["AXChildren":$0] } ?? [:];b.calls=[]
            check("missing/nonpositive child count stops before reading arrays: \(String(describing:count))", collect() == nil && b.calls == ["count:AXChildren"])
        }
        b.counts=["AXChildren":100];b.partial["AXChildren"] = .init(elements:[1,2],subset:.init(count:100,availableRanges:[20..<22]))
        b.calls=[];let boundary=collect()
        check("threshold equality keeps partial array and original descriptor", boundary?.elements == [1,2] && boundary?.subset == .init(count:100,availableRanges:[20..<22]) && !b.calls.contains("supported"))
        b.counts["AXChildren"]=500
        check("large arrays below custom threshold still use supplied partial read", collect(500)?.subset?.count == 100)
        b.partial.removeAll();check("failed small-array read remains unavailable", collect(500) == nil)
        b.counts=["AXChildren":500];b.calls=[]
        check("web event stream refuses count500 before any array read", collect(100,1,true) == nil && b.calls == ["count:AXChildren"])
        b.counts=["AXChildren":499];b.arrays["AXChildren"]=[0,1,2,3,4,5]
        b.parentFrame = .init(x:0,y:0,width:100,height:100)
        b.frames=[0:.init(x:10,y:10,width:4,height:4),1:.init(x:20,y:20,width:4,height:4),2:.init(x:200,y:200,width:4,height:4),3:.init(x:30,y:30,width:4,height:4),4:.init(x:40,y:40,width:4,height:4),5:.init(x:200,y:200,width:4,height:4)]
        b.calls=[];let web=collect(100,1,true)
        check("web event stream preserves all separated visible runs", web?.elements == [0,1,3,4] && web?.subset == .init(count:6,availableRanges:[0..<2,3..<5]))
        check("web path avoids visible attribute discovery", !b.calls.contains("supported") && !b.calls.contains("partial:AXChildren"))
        b.counts["AXChildren"]=500
        check("other contexts do not inherit web-only count gate", collect(500,0,true) == nil)
        b.partial["AXChildren"] = .init(elements:[99],subset:nil)
        check("full context uses normal threshold even for web app", collect(500,0,true)?.elements == [99])
        check("informational context uses normal threshold even for web app", collect(500,2,true)?.elements == [99])
        b.supported=["AXVisibleRows","AXVisibleChildren"];b.counts=["AXChildren":500,"AXVisibleRows":0,"AXVisibleChildren":2]
        b.partial["AXVisibleChildren"] = .init(elements:[4,5],subset:.init(count:7,availableRanges:nil));b.cached.removeAll();b.calls=[]
        let visible=collect()
        check("zero visibleRows count allows positive visibleChildren", visible?.elements == [4,5] && b.calls.contains("partial:AXVisibleChildren") && !b.calls.contains("partial:AXVisibleRows"))
        check("visible array survives unavailable source without fabricated descriptor", visible?.subset == .init(count:7,availableRanges:nil))
        b.counts["AXVisibleRows"]=1;b.partial["AXVisibleRows"] = .init(elements:[77],subset:nil);b.calls=[]
        check("positive visibleRows takes precedence", collect()?.elements == [77] && !b.calls.contains("partial:AXVisibleChildren"))
        b.partial.removeValue(forKey:"AXVisibleRows");b.calls=[]
        check("chosen visible array read failure does not borrow other data", collect() == nil && !b.calls.contains("partial:AXVisibleChildren") && !b.calls.contains("array:AXChildren"))
        b.counts.removeValue(forKey:"AXVisibleRows");b.calls=[]
        check("visibleRows count failure falls through to visibleChildren", collect()?.elements == [4,5] && b.calls.contains("partial:AXVisibleChildren"))
        b.supported=[];b.calls=[]
        check("unsupported visible attributes are not probed for count", collect() == nil && !b.calls.contains("count:AXVisibleChildren"))

        b.cached=["AXRows":[8,4,5,9],"AXChildren":[4,5]];b.calls=[]
        let cached = reader.byVisibleAttribute("AXVisibleChildren",maximum:0)
        check("cached rows source wins over children source", cached?.elements == [4,5] && cached?.subset == .init(count:4,availableRanges:[1..<3]) && !b.calls.contains("cached:AXChildren"))
        b.cached=["AXRows":[4],"AXChildren":[8,4,5,9]];b.calls=[]
        check("cached source must contain every visible identity", reader.byVisibleAttribute("AXVisibleChildren",maximum:0)?.subset?.availableRanges == [1..<3] && b.calls.contains("cached:AXChildren"))
        b.cached.removeAll();b.counts["AXChildren"]=4;b.arrays["AXChildren"]=[8,4,5,9]
        check("mapped attribute source is fetched within count gate", reader.byVisibleAttribute("AXVisibleChildren",maximum:0)?.subset?.count == 4)
        b.counts["AXChildren"]=2;b.calls=[]
        check("equal source/visible counts preserve original partial descriptor", reader.byVisibleAttribute("AXVisibleChildren",maximum:0)?.subset == visible?.subset && !b.calls.contains("array:AXChildren"))
        b.cached=["AXRows":[4,9,5]]
        check("split membership does not replace a longer visible array", reader.byVisibleAttribute("AXVisibleChildren",maximum:0)?.subset == visible?.subset)
        b.cached=["AXRows":[4,4,5]]
        check("source duplicate identities retain actual source positions", reader.byVisibleAttribute("AXVisibleChildren",maximum:0)?.elements == [4,4,5])
        b.equivalence = { $0 % 10 == $1 % 10 };b.hashing = {$0 % 10};b.cached=["AXRows":[14,15]]
        check("native-equivalent identities use backend equality", reader.byVisibleAttribute("AXVisibleChildren",maximum:0)?.elements == [14,15])
        b.equivalence = { $0 == $1 };b.hashing = {_ in 0};b.cached=["AXRows":[8,4,5,9]]
        check("hash collisions still require identity equality",reader.byVisibleAttribute("AXVisibleChildren",maximum:0)?.elements == [4,5])
        b.hashing = {$0};b.cached=["AXRows":Array(0..<5000)];b.partial["AXVisibleChildren"] = .init(elements:Array(1000..<2000),subset:nil);b.comparisons=0
        let many = reader.byVisibleAttribute("AXVisibleChildren",maximum:0)
        check("large cached source membership avoids quadratic native comparisons",many?.subset == .init(count:5000,availableRanges:[1000..<2000]) && b.comparisons <= 5000)
        b.partial["AXVisibleChildren"] = .init(elements:[],subset:.init(count:10,availableRanges:[]));b.cached=["AXRows":[1,2]]
        check("empty visible list keeps its supplied metadata", reader.byVisibleAttribute("AXVisibleChildren",maximum:0)?.subset == .init(count:10,availableRanges:[]))

        b.cached.removeAll();b.arrays["AXChildren"]=[0,1,2,3,4,5]
        b.supported=[];b.counts=["AXChildren":499];b.calls=[]
        let fallback=collect()
        check("ordinary count499 uses geometry and surrounding100", fallback?.elements == [0,1,2,3,4,5] && fallback?.subset == .init(count:6,availableRanges:nil) && b.calls.contains("frame"))
        b.partial["AXChildren"] = .init(elements:[],subset:nil);b.counts=["AXChildren":1]
        check("count/read race may return an available empty array",collect()?.elements.isEmpty == true)
        let largest=reader.byPosition(maximum:0,includeAllRanges:false,clippingFrame:nil)
        check("equal-size visible runs choose the later run", largest?.elements == [3,4])
        check("largest-run descriptor records full source count", largest?.subset == .init(count:6,availableRanges:[3..<5]))
        let widened=reader.byPosition(maximum:5,includeAllRanges:false,clippingFrame:nil)
        check("surrounding elements expand left first then alternate", widened?.elements == [1,2,3,4,5] && widened?.subset?.availableRanges == [1..<6])
        let complete=reader.byPosition(maximum:Int.max,includeAllRanges:false,clippingFrame:nil)
        check("full coverage has present descriptor with nil ranges", complete?.elements == [0,1,2,3,4,5] && complete?.subset == .init(count:6,availableRanges:nil))
        let clip=reader.byPosition(maximum:0,includeAllRanges:true,clippingFrame:.init(x:25,y:25,width:25,height:25))
        check("clipping intersects parent frame before visibility tests", clip?.elements == [3,4])
        check("disjoint clip yields unavailable rather than an empty success", reader.byPosition(maximum:0,includeAllRanges:true,clippingFrame:.init(x:300,y:300,width:10,height:10)) == nil)
        b.parentFrame=nil
        check("missing parent frame uses zero and produces no visible children", reader.byPosition(maximum:0,includeAllRanges:true,clippingFrame:nil) == nil)
        b.parentFrame = .init(x:0,y:0,width:100,height:100);b.frames=[0:.init(x:0,y:20,width:1,height:10),1:.init(x:99,y:20,width:1,height:10),2:.init(x:1,y:20,width:1,height:10)]
        check("one-point inset excludes edge-only children", reader.byPosition(maximum:0,includeAllRanges:true,clippingFrame:nil)?.elements == [2])
        b.frames.removeAll();b.calls=[]
        check("missing child AXFrame does not use an invented geometry", reader.byPosition(maximum:0,includeAllRanges:true,clippingFrame:nil) == nil && b.calls.contains("frame:0"))

        typealias Policy = EventStreamChildren<Backend>
        check("empty/no-visible masks contain no ranges", Policy.ranges([]).isEmpty && Policy.ranges([false,false]).isEmpty)
        check("visible runs retain half-open source indices", Policy.ranges([true,false,true,true,false,true]) == [0..<1,2..<4,5..<6])
        check("larger run wins over later smaller run", Policy.largestRange([0..<3,5..<6]) == 0..<3)
        check("range expansion never truncates an already larger run", Policy.expand(2..<7,maximum:2,count:10) == 2..<7)
        check("left edge continues expanding right", Policy.expand(0..<1,maximum:5,count:6) == 0..<5)
        check("right edge continues expanding left", Policy.expand(5..<6,maximum:5,count:6) == 1..<6)
        check("zero or negative expansion keeps initial run", Policy.expand(2..<3,maximum:0,count:10) == 2..<3 && Policy.expand(2..<3,maximum:-1,count:10) == 2..<3)
        print("EVENT STREAM CHILD COLLECTION: \(checks) checks passed")
    }
}
