import Foundation

struct EventStreamRenderCursor<Identity:Hashable> {
    let node:EventStreamRenderedNode<Identity>
    let path:[Int]
    var depth:Int {path.count-1}
    var children:[Self] {
        node.children.enumerated().map {Self(node:$0.element,path:path+[$0.offset])}
    }
}

// Counting is deferred, consumes a stack from the
// end, and reads a node's children when that node is consumed.
struct EventStreamRenderTraversalCounter<Identity:Hashable>:ExpressibleByIntegerLiteral {
    private var pending:[EventStreamRenderedNode<Identity>]
    private(set) var count:Int
    init(integerLiteral value:Int) {pending=[];count=value}
    init(items:[EventStreamRenderedNode<Identity>]) {pending=items;count=0}
    var isEmpty:Bool {pending.isEmpty}
    mutating func increment(while predicate:(Int)->Bool)->Int {
        guard predicate(count) else {return count}
        while let node=pending.popLast() {
            pending.append(contentsOf:node.children)
            count += 1
            if !predicate(count) {break}
        }
        return count
    }
    mutating func total()->Int {increment(while:{_ in true})}
    mutating func add(counter:Self) {
        pending.append(contentsOf:counter.pending)
        count += counter.count
    }
}

enum EventStreamRenderChange<Identity:Hashable>:CustomStringConvertible {
    typealias Cursor=EventStreamRenderCursor<Identity>
    case none(offset:Int,new:Cursor,old:Cursor)
    case insert(offset:Int,new:Cursor)
    case update(offset:Int,new:Cursor,old:Cursor)
    case remove(offset:Int,old:Cursor)
    enum Kind:Int {case none,insert,update,remove}
    var kind:Kind {
        switch self {case .none:return .none;case .insert:return .insert;case .update:return .update;case .remove:return .remove}
    }
    var offset:Int {
        switch self {case let .none(n,_,_),let .insert(n,_),let .update(n,_,_),let .remove(n,_):return n}
    }
    var new:Cursor? {
        switch self {case let .none(_,n,_),let .insert(_,n),let .update(_,n,_):return n;case .remove:return nil}
    }
    var old:Cursor? {
        switch self {case let .none(_,_,o),let .update(_,_,o),let .remove(_,o):return o;case .insert:return nil}
    }
    var path:[Int] {(new ?? old!).path}
    // The description reads current text from retained references.
    var description:String {
        switch self {
        case let .none(n,new,old):return "No change at \(n) from '\(old.node.text)' to '\(new.node.text)'."
        case let .update(n,new,old):return "Update at \(n) from '\(old.node.text)' to '\(new.node.text)'."
        case let .insert(n,new):return "Insertion at \(n) with '\(new.node.text)'."
        case let .remove(n,old):return "Removal at \(n) with '\(old.node.text)'."
        }
    }
    // Equal-path order differs from the enum's payload tags.
    var depthFirstRank:Int {
        switch self {case .none:return 0;case .remove:return 1;case .insert:return 2;case .update:return 3}
    }
    @MainActor func inheritElementID() {
        if let old,let new {EventStreamRenderIDs.inherit(from:old.node,to:new.node)}
    }
    func lineCounter(options:EventStreamRenderLineOptions=[])->EventStreamRenderTraversalCounter<Identity> {
        switch self {
        case .none:return 0
        case .update:return 1
        case let .insert(_,cursor):return options.contains(.withoutInsertionSubtree) ? 1:.init(items:[cursor.node])
        case let .remove(_,cursor):return options.contains(.withoutRemovalSubtree) ? 1:.init(items:[cursor.node])
        }
    }
    // Prefix precedes indentation. Subtree depths
    // start at zero then add the outer cursor depth; sourcePath is unrelated.
    func lines(indent:Character="\t",options:EventStreamRenderLineOptions=[])->[String] {
        let cursor:Cursor,prefix:String,single:Bool
        switch self {
        case .none:return []
        case let .update(_,n,_):cursor=n;prefix="~";single=true
        case let .insert(_,n):cursor=n;prefix="+";single=options.contains(.withoutInsertionSubtree)
        case let .remove(_,o):cursor=o;prefix="-";single=options.contains(.withoutRemovalSubtree)
        }
        if single {return [prefix+cursor.node.line(indent:indent,depth:cursor.depth,options:options)]}
        var work=[(cursor.node,0)],result:[String]=[]
        while let (node,depth)=work.popLast() {
            result.append(prefix+node.line(indent:indent,depth:cursor.depth+depth,options:options))
            work.append(contentsOf:node.children.reversed().map {($0,depth+1)})
        }
        return result
    }
}

// Value queue with consumed slots cleared, retaining only live payloads.
private struct EventStreamRenderQueue<Value> {
    private var values:[Value?]=[]
    private var head=0
    var isEmpty:Bool {head==values.count}
    mutating func append(_ value:Value) {values.append(value)}
    mutating func popFirst()->Value? {
        guard !isEmpty else {return nil}
        let value=values[head];values[head]=nil;head += 1
        if head==values.count {values.removeAll(keepingCapacity:true);head=0}
        else if head>256 && head>values.count/2 {values.removeFirst(head);head=0}
        return value
    }
}

// Preserve root arrays by value and nodes by reference.
// Each structural sibling pair produces its whole change batch before a child
// pair is consumed. This sequence includes unchanged pairs for ID inheritance.
struct EventStreamRenderDifference<Identity:Hashable>:Sequence {
    typealias Element=EventStreamRenderChange<Identity>
    typealias Cursor=EventStreamRenderCursor<Identity>
    let oldTree:EventStreamRenderedTree<Identity>
    let newTree:EventStreamRenderedTree<Identity>
    func makeIterator()->Iterator {Iterator(old:oldTree.roots,new:newTree.roots)}
    func buffer()->EventStreamRenderDifferenceBuffer<Identity> {.init(difference:self)}
    struct Iterator:IteratorProtocol {
        private var pairs=EventStreamRenderQueue<(old:[Cursor],new:[Cursor])>()
        private var changes=EventStreamRenderQueue<Element>()
        init(old:[EventStreamRenderedNode<Identity>],new:[EventStreamRenderedNode<Identity>]) {
            pairs.append((old.enumerated().map {Cursor(node:$0.element,path:[$0.offset])},
                          new.enumerated().map {Cursor(node:$0.element,path:[$0.offset])}))
        }
        mutating func next()->Element? {
            while changes.isEmpty {
                guard let pair=pairs.popFirst() else {return nil}
                compare(old:pair.old,new:pair.new)
            }
            return changes.popFirst()
        }
        private mutating func paired(offset:Int,new:Cursor,old:Cursor) {
            if !new.node.children.isEmpty || !old.node.children.isEmpty {pairs.append((old.children,new.children))}
            if old.node.text==new.node.text {changes.append(.none(offset:offset,new:new,old:old))}
            else {changes.append(.update(offset:offset,new:new,old:old))}
        }
        // Common prefix, then LAST old cursor per identity. A mapping is
        // consumed before the subsequence membership test: rejected moves emit
        // insertion only, not an extra synthetic removal.
        private mutating func compare(old:[Cursor],new:[Cursor]) {
            var prefix=0
            while prefix<Swift.min(old.count,new.count),old[prefix].node.identity==new[prefix].node.identity {
                paired(offset:prefix,new:new[prefix],old:old[prefix]);prefix += 1
            }
            var remaining:[Identity:(offset:Int,cursor:Cursor)]=[:]
            for i in prefix..<old.count {remaining[old[i].node.identity]=(i,old[i])}
            let matches=new.dropFirst(prefix).compactMap {cursor->(Identity,Int)? in
                remaining[cursor.node.identity].map {(cursor.node.identity,$0.offset)}
            }
            let selected=Self.orderedIdentities(matches)
            for i in prefix..<new.count {
                let n=new[i]
                if let o=remaining.removeValue(forKey:n.node.identity),selected?.contains(n.node.identity) ?? true {
                    paired(offset:i,new:n,old:o.cursor)
                } else {changes.append(.insert(offset:i,new:n))}
            }
            // No imposed order: iterate the dictionary values.
            for old in remaining.values {changes.append(.remove(offset:old.offset,old:old.cursor))}
        }
        // Nil fast path for strictly
        // increasing offsets; otherwise suffix LIS lengths choose the earliest
        // feasible matches in NEW order, returning native identities as a Set.
        private static func orderedIdentities(_ matches:[(Identity,Int)])->Set<Identity>? {
            var previous = -1,ordered=true
            for (_,offset) in matches {
                if previous>=offset {ordered=false;break};previous=offset
            }
            if ordered {return nil}
            var tails:[Int]=[],lengths=Array(repeating:0,count:matches.count)
            for i in matches.indices.reversed() {
                let value = -matches[i].1
                var lower=0,upper=tails.count
                while lower<upper {
                    let middle=(lower+upper)/2
                    if tails[middle]<value {lower=middle+1} else {upper=middle}
                }
                lengths[i]=lower+1
                if lower==tails.count {tails.append(value)} else {tails[lower]=value}
            }
            var needed=tails.count,result:Set<Identity>=[];previous = -1
            for (i,match) in matches.enumerated() where needed>0 && match.1>previous && lengths[i]>=needed {
                result.insert(match.0);previous=match.1;needed -= 1
            }
            return result
        }
    }
}

struct EventStreamRenderDifferenceBuffer<Identity:Hashable> {
    let difference:EventStreamRenderDifference<Identity>
    private(set) var changes:[EventStreamRenderChange<Identity>]
    private(set) var sortedDepthFirst=false
    init(difference:EventStreamRenderDifference<Identity>) {self.difference=difference;changes=Array(difference)}
    // Sort once; paths are render cursor paths,
    // not source paths and not offsets in the previous capture.
    mutating func sortChangesDepthFirst() {
        guard !sortedDepthFirst else {return}
        changes.sort {
            let a=IndexPath(indexes:$0.path),b=IndexPath(indexes:$1.path)
            let order=a.compare(b)
            return order == .orderedSame ? $0.depthFirstRank<$1.depthFirstRank:order == .orderedAscending
        }
        sortedDepthFirst=true
    }
}
