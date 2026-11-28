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

/// The accessibility prefetch stops each child list at its array limit, and
/// does not always report how long the list really is. A prefetched list at
/// least `checkedFrom` long is checked against a live count, so that a cut
/// list is known to be cut and its first elements are marked as a subset.
enum EventStreamChildCoverage {
    /// The smallest array limit the prefetch is given.
    static let checkedFrom = 20

    static func verify(_ cached: EventStreamArraySubset, liveCount: () -> Int?) -> EventStreamArraySubset {
        guard cached.availableRanges == nil, cached.count >= checkedFrom,
              let total = liveCount(), total > cached.count else { return cached }
        return .init(count: total, availableRanges: [0..<cached.count])
    }

    /// The coverage of a parent's child list as the snapshot holds it: the
    /// prefetch's own record when there is one, otherwise a cached array,
    /// which is reported only when it turns out to be cut.
    static func checked(prefetched: EventStreamArraySubset?, cachedCount: Int?,
                        liveCount: () -> Int?) -> EventStreamArraySubset? {
        if let prefetched { return verify(prefetched, liveCount: liveCount) }
        guard let cachedCount else { return nil }
        let checked = verify(.init(count: cachedCount, availableRanges: nil), liveCount: liveCount)
        return checked.availableRanges == nil ? nil : checked
    }
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
        // Without a visible run, or with too many children to place, the
        // prefetched first children are still listed, marked as a subset.
        guard count <= 499 else { return knownPrefix() }
        return byPosition(maximum: 100, includeAllRanges: false, keepingOtherRanges: true, clippingFrame: nil)
            ?? knownPrefix()
    }

    /// The prefetched start of a list that is known to be longer.
    private func knownPrefix() -> EventStreamChildArray<Backend.Element>? {
        guard let prefix = backend.partialArray("AXChildren"), prefix.subset?.availableRanges != nil else { return nil }
        return prefix
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

    /// Children by where they are on screen. The largest visible run is
    /// widened to `maximum` children. With `keepingOtherRanges`, the other
    /// visible runs are kept as well, so that an element drawn on screen
    /// (a dialog after a long list, say) is not left out of the tree.
    func byPosition(maximum: Int, includeAllRanges: Bool, keepingOtherRanges: Bool = false,
                    clippingFrame: CGRect?) -> EventStreamChildArray<Backend.Element>? {
        guard let source = backend.array("AXChildren") else { return nil }
        var frame = backend.frame() ?? .zero
        if let clippingFrame { frame = frame.intersection(clippingFrame) }
        let inset = frame.insetBy(dx: 1, dy: 1)
        let matches = source.map { inset.intersects(backend.uncachedFrame($0) ?? .zero) }
        let ranges = Self.ranges(matches)
        guard !ranges.isEmpty else { return nil }
        if includeAllRanges { return Self.select(source, ranges: ranges) }
        guard let range = Self.largestRange(ranges) else { return nil }
        let widened = Self.expand(range, maximum: maximum, count: source.count)
        guard keepingOtherRanges else { return Self.select(source, ranges: [widened]) }
        return Self.select(source, ranges: Self.merge(ranges + [widened]))
    }

    /// Sorted ranges, with overlapping and touching ones joined.
    static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else { result.append(range) }
        }
        return result
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
