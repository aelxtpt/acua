import Foundation
import CoreGraphics

struct EventStreamArraySubset: Equatable {
    let count: Int
    let availableRanges: [Range<Int>]?
}

struct EventStreamChildArray<Element> {
    let elements: [Element]
    let subset: EventStreamArraySubset?
}

// Child selection. A provider must distinguish cached arrays, complete
// reads, partial arrays and uncached child AXFrame.
@MainActor protocol EventStreamChildrenBackend {
    associatedtype Element
    func count(_ attribute: String) -> Int?
    func supportedAttributes() -> Set<String>
    func partialArray(_ attribute: String) -> EventStreamChildArray<Element>?
    func cachedArray(_ attribute: String) -> [Element]?
    func array(_ attribute: String) -> [Element]?
    func frame() -> CGRect?
    func uncachedFrame(_ element: Element) -> CGRect?
    func equal(_ lhs: Element, _ rhs: Element) -> Bool
    func hash(_ element: Element) -> Int
}

@MainActor struct EventStreamChildren<Backend: EventStreamChildrenBackend> {
    let backend: Backend

    func collect(threshold: Int = 100, contextKind: UInt8, isWebShaped: Bool,
                 clippingFrame: CGRect? = nil) -> EventStreamChildArray<Backend.Element>? {
        guard let count = backend.count("AXChildren"), count > 0 else { return nil }
        if contextKind == 1 && isWebShaped {
            guard count <= 499 else { return nil }
            return byPosition(maximum: 0, includeAllRanges: true, clippingFrame: clippingFrame)
        }
        guard count > threshold else { return backend.partialArray("AXChildren") }
        let supported = backend.supportedAttributes()
        // visibleRows wins only with a positive count; an empty supported
        // attribute does not hide visibleChildren.
        if let attribute = ["AXVisibleRows", "AXVisibleChildren"].first(where: {
            supported.contains($0) && (backend.count($0) ?? 0) > 0
        }) {
            // Once an attribute is selected, its read failure does not trigger
            // the position fallback.
            return byVisibleAttribute(attribute, maximum: 0)
        }
        guard count <= 499 else { return nil }
        return byPosition(maximum: 100, includeAllRanges: false, clippingFrame: nil)
    }

    func byVisibleAttribute(_ attribute: String, maximum: Int) -> EventStreamChildArray<Backend.Element>? {
        guard let visible = backend.partialArray(attribute) else { return nil }
        guard let source = sourceArray(for: attribute, visible: visible.elements) else { return visible }
        let visibleIndex = index(visible.elements)
        let matches = source.map { element in contains(element, in: visibleIndex) }
        guard let range = Self.largestRange(Self.ranges(matches)), range.count >= visible.elements.count else { return visible }
        return Self.select(source, ranges: [Self.expand(range, maximum: maximum, count: source.count)])
    }

    private func sourceArray(for attribute: String, visible: [Backend.Element]) -> [Backend.Element]? {
        // First cached rows/children array that contains every visible element,
        // including an empty visible array. Do not refresh it.
        for name in ["AXRows", "AXChildren"] {
            if let source = backend.cachedArray(name) {
                let sourceIndex = index(source)
                if visible.allSatisfy({ contains($0, in: sourceIndex) }) { return source }
            }
        }
        let name: String
        switch attribute {
        case "AXVisibleRows": name = "AXRows"
        case "AXVisibleChildren": name = "AXChildren"
        default: return nil
        }
        guard let count = backend.count(name), count > 0, count <= 499, visible.count < count else { return nil }
        return backend.array(name)
    }

    private func index(_ elements: [Backend.Element]) -> [Int:[Backend.Element]] {
        Dictionary(grouping: elements, by: backend.hash)
    }
    private func contains(_ element: Backend.Element, in index: [Int:[Backend.Element]]) -> Bool {
        // Membership uses CFHash + native equality, including collision checks.
        // A backend's equal identities must therefore have equal hashes.
        index[backend.hash(element)]?.contains { backend.equal($0, element) } ?? false
    }

    func byPosition(maximum: Int, includeAllRanges: Bool, clippingFrame: CGRect?) -> EventStreamChildArray<Backend.Element>? {
        guard let source = backend.array("AXChildren") else { return nil }
        var frame = backend.frame() ?? .zero
        if let clippingFrame { frame = frame.intersection(clippingFrame) }
        let inset = frame.insetBy(dx: 1, dy: 1)
        let matches = source.map { inset.intersects(backend.uncachedFrame($0) ?? .zero) }
        let ranges = Self.ranges(matches)
        guard !ranges.isEmpty else { return nil }
        if includeAllRanges { return Self.select(source, ranges: ranges) }
        guard let range = Self.largestRange(ranges) else { return nil }
        return Self.select(source, ranges: [Self.expand(range, maximum: maximum, count: source.count)])
    }

    static func ranges(_ included: [Bool]) -> [Range<Int>] {
        var result: [Range<Int>] = [], start: Int?
        for index in included.indices {
            if included[index] { if start == nil { start = index } }
            else if let first = start { result.append(first..<index); start = nil }
        }
        if let start { result.append(start..<included.count) }
        return result
    }

    static func largestRange(_ ranges: [Range<Int>]) -> Range<Int>? {
        // Sort ascending and take the suffix. Equal lengths pick the last range,
        // rather than the first visible run.
        ranges.reduce(nil) { best, next in best == nil || next.count >= best!.count ? next : best }
    }

    static func expand(_ range: Range<Int>, maximum: Int, count: Int) -> Range<Int> {
        precondition(!range.isEmpty && range.lowerBound >= 0 && range.upperBound <= count)
        guard maximum > range.count else { return range }
        var lower = range.lowerBound, upper = range.upperBound, right = false
        var remaining = min(maximum - range.count, count - range.count)
        // Left first, alternate each step; at an edge keep filling from the
        // other side. The existing visible run is never truncated.
        while remaining > 0 {
            if lower > 0 && !(right && upper < count) { lower -= 1 }
            else if upper < count { upper += 1 }
            right.toggle(); remaining -= 1
        }
        return lower..<upper
    }

    static func select(_ source: [Backend.Element], ranges: [Range<Int>]) -> EventStreamChildArray<Backend.Element>? {
        guard !ranges.isEmpty else { return nil }
        let elements = ranges.flatMap { Array(source[$0]) }
        // Return a present descriptor even when every item was included; only
        // availableRanges becomes nil in that case.
        return .init(elements: elements, subset: .init(count: source.count,
            availableRanges: elements.count == source.count ? nil : ranges))
    }
}
