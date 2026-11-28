import ApplicationServices
import Foundation

// Native AX provider for the child policy. This reads child lists;
// it does not stand in for transformed-node construction or tree revisions.
@MainActor final class EventStreamNativeChildren: EventStreamChildrenBackend {
    typealias Element = EventStreamAXNode
    let parent: EventStreamAXNode
    init(parent: EventStreamAXNode) { self.parent = parent }

    private var coverages: [String: EventStreamArraySubset?] = [:]
    /// The cached list's coverage, checked against a live count when the
    /// prefetch may have cut the list.
    private func coverage(_ attribute: String) -> EventStreamArraySubset? {
        if let known = coverages[attribute] { return known }
        let prefetched = parent.cachedPartialValue(attribute)?.array.map {
            EventStreamArraySubset(count: $0.count, availableRanges: $0.availableRanges)
        }
        let checked = EventStreamChildCoverage.checked(prefetched: prefetched,
            cachedCount: (parent.cachedAttribute(attribute) as? [AnyObject])?.count) { liveCount(attribute) }
        coverages[attribute] = .some(checked)
        return checked
    }
    private func liveCount(_ attribute: String) -> Int? {
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(parent.element, attribute as CFString, &count) == .success else { return nil }
        return count
    }

    func count(_ attribute: String) -> Int? {
        guard parent.mayReadAttribute(attribute) else {return nil}
        if let coverage=coverage(attribute) {return coverage.count}
        if let cached = parent.cachedAttribute(attribute) {
            guard CFGetTypeID(cached) == CFArrayGetTypeID(), let values = cached as? [AnyObject] else { return 0 }
            return values.count
        }
        return liveCount(attribute)
    }
    func supportedAttributes() -> Set<String> {
        parent.supportedAttributeNames()
    }
    func partialArray(_ attribute: String) -> EventStreamChildArray<Element>? {
        guard let elements = decode(parent.attribute(attribute)) else { return nil }
        return .init(elements:elements,subset:coverage(attribute))
    }
    func cachedArray(_ attribute: String) -> [Element]? { decode(parent.cachedAttribute(attribute)) }
    func array(_ attribute: String) -> [Element]? {
        // A prefetched list known to be cut is read again in full.
        if let cached = parent.cachedAttribute(attribute), coverage(attribute)?.availableRanges == nil { return decode(cached) }
        guard parent.mayReadAttribute(attribute) else {return nil}
        return decode(raw(parent.element, attribute))
    }
    func frame() -> CGRect? {
        if let frame = rect(parent.attribute("AXFrame")) { return frame }
        guard let position = parent.attribute("AXPosition"), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = parent.attribute("AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let p = unsafeDowncast(position, to: AXValue.self), s = unsafeDowncast(size, to: AXValue.self)
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(p) == .cgPoint, AXValueGetValue(p, .cgPoint, &point),
              AXValueGetType(s) == .cgSize, AXValueGetValue(s, .cgSize, &dimensions) else { return nil }
        return .init(origin: point, size: dimensions)
    }
    func uncachedFrame(_ element: Element) -> CGRect? { rect(raw(element.element, "AXFrame")) }
    func equal(_ lhs: Element, _ rhs: Element) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(_ element: Element) -> Int { Int(bitPattern:CFHash(element.element)) }

    private func raw(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success ? value : nil
    }
    private func rect(_ raw: AnyObject?) -> CGRect? {
        guard let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(raw, to: AXValue.self)
        var frame = CGRect.zero
        guard AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &frame) else { return nil }
        return frame
    }
    private func decode(_ raw: AnyObject?) -> [Element]? {
        guard let raw, CFGetTypeID(raw) == CFArrayGetTypeID(), let values = raw as? [AnyObject],
              values.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
        return values.map { parent.relatedNode(unsafeDowncast($0, to: AXUIElement.self)) }
    }
}
