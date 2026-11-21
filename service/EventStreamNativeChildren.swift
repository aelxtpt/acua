import ApplicationServices
import Foundation

// Native AX provider for the child policy. This reads child lists;
// it does not stand in for transformed-node construction or tree revisions.
@MainActor final class EventStreamNativeChildren: EventStreamChildrenBackend {
    typealias Element = EventStreamAXNode
    let parent: EventStreamAXNode
    init(parent: EventStreamAXNode) { self.parent = parent }

    func count(_ attribute: String) -> Int? {
        guard parent.mayReadAttribute(attribute) else {return nil}
        if let coverage=parent.cachedPartialValue(attribute)?.array {return coverage.count}
        if let cached = parent.cachedAttribute(attribute) {
            guard CFGetTypeID(cached) == CFArrayGetTypeID(), let values = cached as? [AnyObject] else { return 0 }
            return values.count
        }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(parent.element, attribute as CFString, &count) == .success else { return nil }
        return count
    }
    func supportedAttributes() -> Set<String> {
        parent.supportedAttributeNames()
    }
    func partialArray(_ attribute: String) -> EventStreamChildArray<Element>? {
        guard let elements = decode(parent.attribute(attribute)) else { return nil }
        let coverage=parent.cachedPartialValue(attribute)?.array
        return .init(elements:elements,subset:coverage.map {.init(count:$0.count,availableRanges:$0.availableRanges)})
    }
    func cachedArray(_ attribute: String) -> [Element]? { decode(parent.cachedAttribute(attribute)) }
    func array(_ attribute: String) -> [Element]? {
        if let cached = parent.cachedAttribute(attribute) { return decode(cached) }
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
