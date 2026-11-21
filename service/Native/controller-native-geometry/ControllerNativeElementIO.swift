import ApplicationServices
import Foundation

/// A present hosted node owns every result, including nil and errors. Only an
/// absent node permits a raw AX call. The global tree owner supplies lookup.
protocol ControllerNativeElementBridge: AnyObject, Sendable {
    var ordinaryPID: Int32 { get }
    var actualPID: Int32 { get }
    var windowID: UInt32 { get }
    var bundleIdentifier: String? { get }
    func supported() -> Set<String>
    func batch(_ attributes: Set<String>) throws -> [String: ControllerNativeAXValue]
    func read(_ attribute: String) throws -> ControllerNativeAXValue?
    func perform(_ action: String) throws
    func actions() -> [String]
    func count(_ attribute: String) -> Int?
    func isSettable(_ attribute: String) -> Bool
    func setBoolean(_ attribute: String, _ value: Bool) throws
}

struct ControllerNativeElementIO: Sendable {
    typealias Lookup = @Sendable (SettingsNativeAXElement) -> (any ControllerNativeElementBridge)?
    let lookup: Lookup

    func bind(_ context: ControllerNativeElementContext) -> ControllerNativeElementContext {
        var bound = context
        let raw = context.context.environment
        bound.io = .init(supported: { key in
            if let bridge = lookup(key) { return bridge.supported() }
            return raw.supported(key)
        }, batch: { key, attributes in
            if let bridge = lookup(key) { return try bridge.batch(attributes) }
            return try raw.batch(key, attributes)
        }, read: { key, name in
            if let bridge = lookup(key) { return try bridge.read(name) }
            return try raw.read(key, name)
        })
        return bound
    }

    func perform(_ action: String, on key: SettingsNativeAXElement,
                 context: ControllerNativeElementContext) throws {
        if let bridge = lookup(key) { try bridge.perform(action); return }
        // Resolve actualPID only for the self/main-thread dispatch.
        let target: Int32?
        do { target = try context.identity.actualPID(key) }
        catch { context.log("actualPID", error); target = nil }
        let raw: @Sendable () throws -> Void = {
            let status = AXUIElementPerformAction(key.element, action as CFString)
            guard [.success, .cannotComplete, .attributeUnsupported].contains(status) else {
                throw ControllerNativeElementDecoding.Failure.accessibility(status.rawValue)
            }
        }
        if target == getpid() && !Thread.isMainThread { try DispatchQueue.main.sync(execute: raw) }
        else { try raw() }
    }
    func actions(_ key: SettingsNativeAXElement) -> [String] {
        if let bridge = lookup(key) { return bridge.actions() }
        var result: CFArray?
        _ = AXUIElementCopyActionNames(key.element, &result)
        return result as? [String] ?? []
    }
    func count(_ name: String, on key: SettingsNativeAXElement) -> Int? {
        if let bridge = lookup(key) { return bridge.count(name) }
        var count = 0
        return AXUIElementGetAttributeValueCount(key.element, name as CFString, &count) == .success ? count : nil
    }
    func isSettable(_ name: String, on key: SettingsNativeAXElement) -> Bool {
        if let bridge = lookup(key) { return bridge.isSettable(name) }
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(key.element, name as CFString, &settable) == .success && settable.boolValue
    }
    func setBoolean(_ name: String, _ value: Bool, on key: SettingsNativeAXElement,
                    context: ControllerNativeElementContext) throws {
        try ControllerAXEnablementNative.set(key, attribute: name, value: value, context: context, bridgedWrite: { key, name, value in
            guard let bridge = lookup(key) else { return false }
            try bridge.setBoolean(name, value)
            return true
        })
    }
}
