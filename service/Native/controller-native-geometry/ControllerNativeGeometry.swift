import ApplicationServices
import Foundation

enum ControllerNativeGeometryDecoding {
    /// Cast the decoded Optional<Any> to T, preserving T == CGPoint?.
    static func decode<T>(_ value: ControllerNativeAXValue, as: T.Type, strict: Bool) throws -> T? {
        do {
            guard CFGetTypeID(value.raw) == AXValueGetTypeID() else {
                if let typed = value.raw as? T { return .some(typed) }
                throw ControllerNativeElementDecoding.Failure.typeMismatch
            }
            let native = unsafeDowncast(value.raw, to: AXValue.self)
            let decoded: Any?
            switch AXValueGetType(native) {
            case .cgPoint:
                var point = CGPoint.zero
                decoded = AXValueGetValue(native, .cgPoint, &point) ? point : nil
            case .cgSize:
                var size = CGSize.zero
                decoded = AXValueGetValue(native, .cgSize, &size) ? size : nil
            case .cgRect:
                var rect = CGRect.zero
                decoded = AXValueGetValue(native, .cgRect, &rect) ? rect : nil
            case .cfRange:
                var range = CFRange(location: 0, length: 0)
                decoded = AXValueGetValue(native, .cfRange, &range) ? range : nil
            case .axError:
                var error = AXError.success
                decoded = AXValueGetValue(native, .axError, &error) ? error : nil
            default: throw ControllerNativeElementDecoding.Failure.typeMismatch
            }
            return try castDecoded(decoded, as: T.self)
        } catch {
            if strict { throw error }
            return nil
        }
    }
    static func castDecoded<T>(_ decoded: Any?, as: T.Type) throws -> T? {
        if let typed = decoded as? T { return .some(typed) }
        if let error = decoded as? AXError {
            if error == .noValue { return nil }
            throw ControllerNativeElementDecoding.Failure.accessibility(error.rawValue)
        }
        throw ControllerNativeElementDecoding.Failure.typeMismatch
    }
}

struct ControllerNativeGeometry: Sendable {
    typealias Node = ControllerNativeElementContext.Node
    let context: ControllerNativeElementContext
    let io: ControllerNativeElementIO

    func value<T>(_ name: String, on node: Node, as: T.Type = T.self) -> T? {
        if let cached = node.snapshot.values[name],
           let typed = try? ControllerNativeGeometryDecoding.decode(cached, as: T.self, strict: false) { return .some(typed) }
        guard EventStreamAttributeAvailability.mayRead(name, supported: node.snapshot.supported,
            requested: node.snapshot.requested) else { return nil }
        do {
            guard let raw = try context.context.environment.read(node.element, name) else { return nil }
            return try ControllerNativeGeometryDecoding.decode(raw, as: T.self, strict: true)
        } catch { context.log(name, error); return nil }
    }
    func activationPoint(_ node: Node) -> CGPoint?? { value("AXActivationPoint", on: node, as: CGPoint?.self) }
    func frame(_ node: Node) -> CGRect? {
        if let rect: CGRect = value("AXFrame", on: node) { return rect }
        guard let position: CGPoint = value("AXPosition", on: node),
              let size: CGSize = value("AXSize", on: node) else { return nil }
        return CGRect(origin: position, size: size)
    }
    func raise(_ node: Node) throws { try NativeElementAction.perform(node, action: "AXRaise", backend: Backend(reader: self)) }

    struct Backend: NativeElementActionBackend {
        let reader: ControllerNativeGeometry
        func identity(_ node: Node) -> SettingsNativeAXElement { node.element }
        func role(_ node: Node) -> String? { reader.context.context.role(node) }
        func subrole(_ node: Node) -> String? { reader.value("AXSubrole", on: node) }
        func parent(_ node: Node) -> Node? { element("AXParent", node) }
        func element(_ name: String, _ node: Node) -> Node? {
            ControllerGlobalFocusNative.element(name, node, context: reader.context)
        }
        func children(_ node: Node) -> [Node] { reader.context.context.children(node) }
        func childrenPreferringVisible(_ node: Node) -> [Node] {
            func supports(_ name: String) -> Bool {
                EventStreamAttributeAvailability.supports(name, supported: node.snapshot.supported,
                    requested: node.snapshot.requested, refresh: { reader.context.context.environment.supported(node.element) })
            }
            let uncachedSupported = reader.context.context.environment.supported(node.element)
            for name in ["AXVisibleRows", "AXVisibleChildren"] where uncachedSupported.contains(name) {
                guard EventStreamAttributeAvailability.mayRead(name, supported: node.snapshot.supported, requested: node.snapshot.requested) else { continue }
                let count: Int?
                if let cached = node.snapshot.values[name] {
                    // Count the encoded array before dropping malformed members.
                    count = CFGetTypeID(cached.raw) == CFArrayGetTypeID() ? CFArrayGetCount(unsafeDowncast(cached.raw, to: CFArray.self)) : nil
                } else { count = reader.io.count(name, on: node.element) }
                if (count ?? 0) > 0 { return elements(name, node) }
            }
            return supports("AXChildren") ? children(node) : []
        }
        private func elements(_ name: String, _ node: Node) -> [Node] {
            if let cached = node.snapshot.values[name], let keys = try? ControllerNativeElementDecoding.elements(cached, strict: false) {
                return keys.map(reader.context.context.node)
            }
            guard EventStreamAttributeAvailability.mayRead(name, supported: node.snapshot.supported, requested: node.snapshot.requested) else { return [] }
            do {
                guard let raw = try reader.context.context.environment.read(node.element, name),
                      let keys = try ControllerNativeElementDecoding.elements(raw, strict: true) else { return [] }
                return keys.map(reader.context.context.node)
            } catch { reader.context.log(name, error); return [] }
        }
        func actions(_ node: Node) -> [String] { reader.io.actions(node.element) }
        func canDisclose(_ node: Node) -> Bool {
            EventStreamAttributeAvailability.supports("AXDisclosing", supported: node.snapshot.supported,
                requested: node.snapshot.requested, refresh: { reader.context.context.environment.supported(node.element) }) &&
                reader.io.isSettable("AXDisclosing", on: node.element)
        }
        func isDisclosing(_ node: Node) -> Bool { reader.value("AXDisclosing", on: node) ?? false }
        func setDisclosing(_ value: Bool, for node: Node) throws { try reader.io.setBoolean("AXDisclosing", value, on: node.element, context: reader.context) }
        func scrollBar(_ node: Node, vertical: Bool) -> Node? { element(vertical ? "AXVerticalScrollBar" : "AXHorizontalScrollBar", node) }
        func performAX(_ action: String, on node: Node) throws { try reader.io.perform(action, on: node.element, context: reader.context) }
        func checkpoint() {}
    }
}
