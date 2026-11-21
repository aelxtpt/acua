// 0x1007B2B10/0x1007C1BB8. Depth zero is self; when excluding self,
// construction reads the first parent and starts its depth at one. next()
// prefetches the next parent before returning the current node. Repeated
// nodes remain in the bounded sequence, including malformed cycles.
struct AXParentChain<Element>: Sequence {
    private let first: Element?
    private let firstDepth: Int
    private let maximumDepth: Int
    private let parent: (Element) -> Element?

    init(start: Element?, maximumDepth: Int = 300, includingSelf: Bool = true,
         parent: @escaping (Element) -> Element?) {
        self.first = includingSelf ? start : start.flatMap(parent)
        self.firstDepth = includingSelf ? 0 : 1
        self.maximumDepth = maximumDepth
        self.parent = parent
    }
    struct Iterator: IteratorProtocol {
        var current: Element?
        var depth: Int
        let maximumDepth: Int
        let parent: (Element) -> Element?
        mutating func next() -> Element? {
            guard let value = current, depth <= maximumDepth else { return nil }
            current = parent(value)
            depth += 1
            return value
        }
    }
    func makeIterator() -> Iterator {
        Iterator(current: first, depth: firstDepth, maximumDepth: maximumDepth, parent: parent)
    }
}
