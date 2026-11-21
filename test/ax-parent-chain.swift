@main enum ParentChainTests {
    static func main() {
        var checks = 0
        func check(_ label: String, _ condition: @autoclosure () -> Bool) {
            precondition(condition(), label); checks += 1; print("PASS \(label)")
        }
        var reads: [Int] = []
        let parent: (Int) -> Int? = { value in reads.append(value); return value + 1 }
        let chain = AXParentChain(start: 0, parent: parent)
        check("including self does not fetch a parent during construction", reads.isEmpty)
        var iterator = chain.makeIterator()
        check("next fetches the parent before yielding self", iterator.next() == 0 && reads == [0])
        check("a consumer that stops early still prefetched one parent", iterator.current == 1)
        reads = []
        let values = Array(chain)
        check("default traversal includes depths zero through 300", values == Array(0...300))
        check("the final included node also fetches its parent", reads == Array(0...300))
        reads = []
        let excluding = AXParentChain(start: 0, includingSelf: false, parent: parent)
        check("excluding self fetches the first parent at construction", reads == [0])
        check("excluding self starts at depth one", Array(excluding) == Array(1...300) && reads == Array(0...300))
        reads = []
        var zero = AXParentChain(start: 0, maximumDepth: 0, parent: parent).makeIterator()
        check("maximum zero includes self and fetches one parent", zero.next() == 0 && reads == [0])
        check("exhausted iterator fetches no more parents", zero.next() == nil && zero.next() == nil && reads == [0])
        reads = []
        let negative = AXParentChain(start: 0, maximumDepth: -1, parent: parent)
        check("negative maximum yields no nodes or parent reads", Array(negative).isEmpty && reads.isEmpty)
        let excludedZero = AXParentChain(start: 0, maximumDepth: 0, includingSelf: false, parent: parent)
        check("excluded self is prefetched even when its depth is out of bounds", Array(excludedZero).isEmpty && reads == [0])
        reads = []
        let empty = AXParentChain<Int>(start: nil, includingSelf: false, parent: parent)
        check("nil start has no parent side effects", Array(empty).isEmpty && reads.isEmpty)
        let finite = AXParentChain(start: 0, parent: { $0 < 2 ? $0 + 1 : nil })
        check("missing parent ends the chain before its limit", Array(finite) == [0, 1, 2])
        let cycle = AXParentChain(start: 0, parent: { 1 - $0 })
        check("cycles repeat until the 300-ancestor bound", Array(cycle) == (0...300).map { $0 % 2 })
        print("\(checks) parent-chain checks passed")
    }
}
