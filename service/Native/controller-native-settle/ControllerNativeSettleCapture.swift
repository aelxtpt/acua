import AppKit
import ApplicationServices
import Foundation

protocol ControllerNativeSettleRichBridge: ControllerNativeElementBridge {
    func actionDescription(_ name: String) throws -> String?
    func string(for range: NSRange) throws -> String?
}
enum ControllerNativeSettleCapabilityFailure: Error { case missingRichBridge }

/// Raw collection and busy inspection share C92's active transaction/fallback
/// cache. Returning this cache keeps the exact transaction and monitor alive
/// for the following C98 selection capture.
@MainActor struct ControllerNativeSettleCapture {
    typealias Node = ControllerNativeElementContext.Node
    let resources: ControllerNativeResources
    var context: ControllerNativeElementContext {
        resources.io.bind(.shared(lookup: resources.context.lookup, log: resources.context.log))
    }
    func wrap(_ element: AXUIElement) -> EventStreamAXNode {
        let context = context, key = SettingsNativeAXElement(element: element)
        let node = context.context.node(key)
        return .init(element, supportedAttributes: node.snapshot.supported, attributes: node.snapshot.values.mapValues(\.raw),
            transactionAttributes: node.snapshot.requested,
            partialValues: EventStreamTreeTransactions.current?.partialValues[.init(element: element)] ?? [:],
            related: { wrap($0) }, attributeReader: { try? context.context.environment.read(key, $0)?.raw })
    }
    func transaction(_ window: Node) -> EventStreamNativeTreeTransaction {
        var table: EventStreamHierarchyCapture.Table = [:], requested: Set<String> = []
        if EventStreamTreeTransactions.prefetchEnabled {
            let attributes = EventStreamSnapshotAttributes.common.union(["AXSelectedRows", "AXSelectedCells", "AXSelectedChildren", "AXDOMClassList", "AXElementBusy", "AXLoaded"])
            if let keys = EventStreamHierarchySPI.keys, EventStreamHierarchySPI.available {
                table = EventStreamHierarchyCapture(keys: keys, copy: EventStreamHierarchySPI.copy)
                    .capture(window.element.element, traversal: ["AXChildren"], attributes: Array(attributes), maximumArrayCount: 100)
            }
            requested = attributes.union(["AXChildren"])
        }
        let raw = table.mapValues { $0.mapValues(\.value) }
        var frequency: [String: Int] = [:]
        for row in raw.values { if let role = row["AXRole"] as? String { frequency[role, default: 0] += 1 } }
        let transaction = EventStreamNativeTreeTransaction(root: window.element.element,
            snapshots: .init(attributeTable: raw, requestedAttributes: requested), partialValues: table, roleFrequency: frequency)
        EventStreamTreeTransactions.$current.withValue(transaction) { _ = context.context.node(window.element) }
        return transaction
    }
    func inspect(application: Node, window: Node, transaction: EventStreamNativeTreeTransaction,
        monitor: EventStreamTreeInvalidationMonitor, webShaped: () -> Bool) -> (busy: Bool, cache: ControllerNativeAppSnapshotCache) {
        let catalyst: Bool = resources.geometry.value("_AXExhibitsMacCatalystBehavior", on: application) ?? false
        let web = webShaped()
        let chromium = webShaped() && traits.firstChildHasChromeNodeID(ControllerNativeAppSnapshotContext.snapshotNode(window, context: resources.context))
        let nodeContext = EventStreamNodeContext(kind: 0, isCatalyst: catalyst, isWebShaped: web, isChromium: chromium,
            windowFrame: resources.geometry.frame(window))
        return EventStreamTreeTransactions.$current.withValue(transaction) {
            let root = wrap(window.element.element)
            let tree = EventStreamTreeCollection(backend: Collection(capture: self)).collect(root, context: nodeContext)
            let busy = ControllerUISettleBusy(backend: Busy(capture: self)).inspect(tree.preorder.map { $0.node.element }, window: root,
                bundle: context.context.environment.bundleIdentifier(application.element))
            return (busy, ControllerNativeAppSnapshotCache(.init(tree: tree, transaction: transaction, invalidationMonitor: monitor)))
        }
    }
    private var traits: EventStreamNativeTransformationContextBackend {
        let raw = EventStreamNativeTransformationContextIO.native
        return .init(io: .init(attribute: { element, name in try? context.context.environment.read(.init(element: element), name)?.raw },
            arrayCount: { element, name in
                if let provider = resources.io.lookup(.init(element: element)) {
                    return provider.count(name).map { (.success, $0) } ?? (.cannotComplete, 0)
                }
                return raw.arrayCount(element, name)
            }, arrayValues: { element, name, index, maximum in
                if let provider = resources.io.lookup(.init(element: element)) {
                    guard let values = try? provider.read(name)?.raw as? [AnyObject], index >= 0, index <= values.count else { return nil }
                    return Array(values.dropFirst(index).prefix(maximum)) as NSArray
                }
                return raw.arrayValues(element, name, index, maximum)
            }, supported: { context.context.environment.supported(.init(element: $0)) },
            processIdentifier: { try ControllerAXEnablementNative.pid(.init(element: $0), lookup: { resources.io.lookup($0)?.ordinaryPID }) }, bundleInfo: raw.bundleInfo))
    }

    struct Collection: EventStreamTreeCollectionBackend {
        typealias Element = EventStreamAXNode; typealias Identity = EventStreamSnapshotAXIdentity
        let capture: ControllerNativeSettleCapture
        func identity(_ element: Element) -> Identity { .init(element: element.element) }
        func construct(_ source: Element, context: EventStreamNodeContext) -> EventStreamTransformedNode<Element> {
            EventStreamNodeConstruction(backend: Fields(capture: capture)).construct(capture.wrap(source.element), context: context)
        }
        func children(_ source: Element, context: EventStreamNodeContext) -> EventStreamChildArray<Element>? {
            EventStreamChildren(backend: Children(capture: capture, node: source)).collect(threshold: 100, contextKind: context.kind,
                isWebShaped: context.isWebShaped, clippingFrame: context.windowFrame)
        }
    }
    struct Fields: EventStreamNodeBackend {
        typealias Element = EventStreamAXNode
        let capture: ControllerNativeSettleCapture
        private let base = EventStreamNativeValueBackend()
        func attributes(_ node: Element) -> [String: AnyObject] { node.cachedAttributesSnapshot() }
        func snapshot(_ node: Element) -> EventStreamValueSnapshot { base.snapshot(node) }
        func freshAttribute(_ name: String, of node: Element) -> AnyObject? { try? capture.context.context.environment.read(.init(element: node.element), name)?.raw }
        func freshSupportedAttributes(_ node: Element) -> Set<String> { capture.context.context.environment.supported(.init(element: node.element)) }
        func isValueSettable(_ node: Element) -> Bool { capture.resources.io.isSettable("AXValue", on: .init(element: node.element)) }
        func string(_ node: Element, for range: NSRange) -> String? {
            if let provider = capture.resources.io.lookup(.init(element: node.element)) {
                return try? (provider as? any ControllerNativeSettleRichBridge)?.string(for: range)
            }
            return base.string(node, for: range)
        }
        func format(_ date: Date, style: EventStreamValueDateStyle) -> String { base.format(date, style: style) }
        func isAttributeSettable(_ name: String, of node: Element) throws -> Bool { capture.resources.io.isSettable(name, on: .init(element: node.element)) }
        func actions(_ node: Element) throws -> [String] { capture.resources.io.actions(.init(element: node.element)) }
        func actionDescription(_ name: String, of node: Element) throws -> String? {
            if let provider = capture.resources.io.lookup(.init(element: node.element)) {
                guard let provider = provider as? any ControllerNativeSettleRichBridge else { throw ControllerNativeSettleCapabilityFailure.missingRichBridge }
                return try provider.actionDescription(name)
            }
            var result: CFString?
            let status = AXUIElementCopyActionDescription(node.element, name as CFString, &result)
            guard status == .success else { throw ControllerNativeElementDecoding.Failure.accessibility(status.rawValue) }
            return result as String?
        }
    }
    final class Children: EventStreamChildrenBackend {
        typealias Element = EventStreamAXNode
        let capture: ControllerNativeSettleCapture, node: Element
        init(capture: ControllerNativeSettleCapture, node: Element) { self.capture = capture; self.node = node }
        private var coverages: [String: EventStreamArraySubset?] = [:]
        /// The cached list's coverage, checked against a live count when the
        /// prefetch may have cut the list.
        private func coverage(_ name: String) -> EventStreamArraySubset? {
            if let known = coverages[name] { return known }
            let prefetched = node.cachedPartialValue(name)?.array.map {
                EventStreamArraySubset(count: $0.count, availableRanges: $0.availableRanges)
            }
            let checked = EventStreamChildCoverage.checked(prefetched: prefetched,
                cachedCount: (node.cachedAttribute(name) as? [AnyObject])?.count) {
                capture.resources.io.count(name, on: .init(element: node.element))
            }
            coverages[name] = .some(checked)
            return checked
        }
        func count(_ name: String) -> Int? {
            guard node.mayReadAttribute(name) else { return nil }
            if let coverage = coverage(name) { return coverage.count }
            if let cached = node.cachedAttribute(name) { return (cached as? [AnyObject])?.count ?? 0 }
            return capture.resources.io.count(name, on: .init(element: node.element))
        }
        func supportedAttributes() -> Set<String> { node.supportedAttributeNames() }
        func partialArray(_ name: String) -> EventStreamChildArray<Element>? {
            guard let elements = decode(node.attribute(name)) else { return nil }
            return .init(elements: elements, subset: coverage(name))
        }
        func cachedArray(_ name: String) -> [Element]? { decode(node.cachedAttribute(name)) }
        func array(_ name: String) -> [Element]? {
            // A prefetched list known to be cut is read again in full.
            if let value = node.cachedAttribute(name), coverage(name)?.availableRanges == nil { return decode(value) }
            guard node.mayReadAttribute(name) else { return nil }
            return decode(try? capture.context.context.environment.read(.init(element: node.element), name)?.raw)
        }
        func frame() -> CGRect? { capture.resources.geometry.frame(ControllerNativeAppSnapshotContext.contextual(node)) }
        func uncachedFrame(_ element: Element) -> CGRect? {
            guard let value = try? capture.context.context.environment.read(.init(element: element.element), "AXFrame") else { return nil }
            return try? ControllerNativeGeometryDecoding.decode(value, as: CGRect.self, strict: true)
        }
        func equal(_ lhs: Element, _ rhs: Element) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(_ element: Element) -> Int { Int(bitPattern: CFHash(element.element)) }
        private func decode(_ value: AnyObject?) -> [Element]? {
            guard let values = value as? [AnyObject] else { return nil }
            return values.compactMap {
                CFGetTypeID($0) == AXUIElementGetTypeID() ? capture.wrap(unsafeDowncast($0, to: AXUIElement.self)) : nil
            }
        }
    }
    struct Busy: ControllerUISettleBusyBackend {
        typealias Node = EventStreamAXNode
        let capture: ControllerNativeSettleCapture
        private func contextual(_ node: Node) -> ControllerNativeElementContext.Node { ControllerNativeAppSnapshotContext.contextual(node) }
        func role(_ node: Node) -> String { node.cachedAttribute("AXRole") as? String ?? "AXUnknown" }
        func children(_ node: Node) -> [Node] { capture.context.context.children(contextual(node)).map { capture.wrap($0.element.element) } }
        func loaded(_ node: Node) -> Bool? { capture.resources.geometry.value("AXLoaded", on: contextual(node)) }
        func supports(_ name: String, _ node: Node) -> Bool { node.supportedAttributeNames().contains(name) }
        func elementBusy(_ node: Node) -> Bool? { capture.resources.geometry.value("AXElementBusy", on: contextual(node)) }
        func classes(_ node: Node) -> [String]? { capture.resources.geometry.value("AXDOMClassList", on: contextual(node)) }
    }
}
