import AppKit
import ApplicationServices
import Foundation
import os

struct ControllerAXEnablementApplication: Hashable, @unchecked Sendable {
    let application: NSRunningApplication
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.application.isEqual(rhs.application) }
    func hash(into hasher: inout Hasher) { hasher.combine(application.hash) }
}

final class ControllerAXEnablementNativeTracker: NSObject, @unchecked Sendable {
    static let shared = ControllerAXEnablementNativeTracker()
    let tracker: ControllerAXEnablementTracker<ControllerAXEnablementApplication>
    private let center: @Sendable () -> NotificationCenter
    init(center: @escaping @Sendable () -> NotificationCenter = { NSWorkspace.shared.notificationCenter }) {
        self.center = center
        tracker = .init(invalidRelease: { _, kind in
            Logger(subsystem: "local.cua", category: "AXEnablement").error("Missing AX assertion count for kind \(kind.rawValue)")
        })
        super.init()
        if Thread.isMainThread { register() }
        else { DispatchQueue.main.async { [self] in register() } }
    }
    private func register() {
        center().addObserver(self, selector: #selector(terminated(_:)), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }
    @objc private func terminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        tracker.applicationTerminated(.init(application: app))
    }
    deinit { center().removeObserver(self, name: NSWorkspace.didTerminateApplicationNotification, object: nil) }
}

private struct ControllerAXPreferences: @unchecked Sendable { let defaults: UserDefaults }

enum ControllerAXEnablementNative {
    typealias Node = ControllerNativeElementContext.Node
    struct Failure: Error { let status: Int32 }

    /// This is the ordinary PID, distinct from cached actualPID. A present cached
    /// PID (including -1/0) is authoritative; never substitute actualPID for it.
    static func pid(_ key: SettingsNativeAXElement,
                    lookup: @Sendable (SettingsNativeAXElement) -> Int32?) throws -> Int32 {
        if let cached = lookup(key) { return cached }
        var pid: pid_t = -1
        let status = AXUIElementGetPid(key.element, &pid)
        guard status == .success else { throw Failure(status: status.rawValue) }
        return pid
    }

    static func set(_ key: SettingsNativeAXElement, attribute: String, value: Bool,
                    context: ControllerNativeElementContext,
                    bridgedWrite: @Sendable (SettingsNativeAXElement, String, Bool) throws -> Bool) throws {
        // The boolean signals absence of a bridged node only. A present node
        // owns the write/error result, with no raw fallback on its failure.
        if try bridgedWrite(key, attribute, value) { return }
        let target: Int32?
        do { target = try context.identity.actualPID(key) }
        catch { context.log("actualPID", error); target = nil }
        let perform: @Sendable () throws -> Void = {
            let status = AXUIElementSetAttributeValue(key.element, attribute as CFString, value ? kCFBooleanTrue : kCFBooleanFalse)
            guard status == .success else { throw Failure(status: status.rawValue) }
        }
        if target == getpid() && !Thread.isMainThread { try DispatchQueue.main.sync(execute: perform) }
        else { try perform() }
    }

    static func boolean(_ node: Node, attribute: String, context: ControllerNativeElementContext) -> Bool? {
        if let value = node.snapshot.values[attribute]?.raw as? Bool { return value }
        guard EventStreamAttributeAvailability.mayRead(attribute, supported: node.snapshot.supported, requested: node.snapshot.requested) else { return nil }
        do {
            guard let value = try context.context.environment.read(node.element, attribute) else { return nil }
            if let boolean = value.raw as? Bool { return boolean }
            if CFGetTypeID(value.raw) == AXValueGetTypeID() {
                let box = unsafeDowncast(value.raw, to: AXValue.self)
                if AXValueGetType(box) == .axError {
                    var error = AXError.success
                    _ = AXValueGetValue(box, .axError, &error)
                    if error == .noValue { return nil }
                    throw Failure(status: error.rawValue)
                }
            }
            throw ControllerNativeElementDecoding.Failure.typeMismatch
        } catch { context.log(attribute, error); return nil }
    }

    static func hasChromeFirstChild(_ node: Node) -> Bool {
        var values: CFArray?
        let status = AXUIElementCopyAttributeValues(node.element.element, "AXChildren" as CFString, 0, 1, &values)
        guard [AXError.success, .noValue, .attributeUnsupported].contains(status), let values,
              let first = try? ControllerNativeElementDecoding.elements(.init(raw: values), strict: false)?.first else { return false }
        var names: CFArray?
        _ = AXUIElementCopyAttributeNames(first.element, &names)
        return (names as? [String] ?? []).contains("ChromeAXNodeId")
    }
    static func hasWebAreaDescendant(_ node: Node, context: ControllerNativeElementContext) -> Bool {
        var queue = context.context.children(node), index = 0
        // Descendant traversal is FIFO, excludes the receiver, and
        // has no invented visited set, node budget or timeout inside the walk.
        while index < queue.count {
            let next = queue[index]; index += 1
            if context.context.role(next) == "AXWebArea" { return true }
            queue.append(contentsOf: context.context.children(next))
        }
        return false
    }

    static func environment<Focus: Sendable>(context: ControllerNativeElementContext,
        pid: @escaping @Sendable (SettingsNativeAXElement) throws -> Int32,
        bridgedWrite: @escaping @Sendable (SettingsNativeAXElement, String, Bool) throws -> Bool,
        makeFocus: @escaping @Sendable (ControllerAXEnablementApplication) -> Focus,
        enforceFocus: @escaping @Sendable (Focus, Node?) throws -> Void,
        deactivateFocus: @escaping @Sendable (Focus) throws -> Void)
        -> ControllerAXEnablement<ControllerAXEnablementApplication, Node, Focus>.Environment {
        typealias Operation = ControllerAXEnablement<ControllerAXEnablementApplication, Node, Focus>
        return .init(resolveApplication: { node in
            guard let resolved = try? pid(node.element), let app = NSRunningApplication(processIdentifier: resolved),
                  let bundle = app.bundleIdentifier else { return nil }
            return (.init(application: app), bundle)
        }, supportsManual: { node in
            EventStreamAttributeAvailability.supports("AXManualAccessibility", supported: node.snapshot.supported,
                requested: node.snapshot.requested, refresh: { context.context.environment.supported(node.element) })
        }, boolean: { boolean($0, attribute: $1, context: context) },
            setBoolean: { try set($0.element, attribute: $1, value: $2, context: context, bridgedWrite: bridgedWrite) },
            isActive: { $0.application.isActive }, makeFocus: makeFocus, enforceFocus: enforceFocus, deactivateFocus: deactivateFocus,
            makePreferences: {
                guard let raw = UserDefaults(suiteName: "com.apple.universalaccess") else { return nil }
                let prefs = ControllerAXPreferences(defaults: raw)
                return Operation.Preferences(read: { prefs.defaults.bool(forKey: "voiceOverOnOffKey") },
                    write: { prefs.defaults.set($0, forKey: "voiceOverOnOffKey") })
            }, notifyPreferences: {
                DistributedNotificationCenter().post(name: .init("com.apple.universalaccess.VoiceOverSettingsDidChange"), object: nil)
            }, voiceOverApplicationExists: { !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").isEmpty },
            schedulePulse: { prefs in
                Task {
                    do { try await ContinuousClock().sleep(for: .milliseconds(100)) }
                    catch { return }
                    prefs.write(false)
                }
            }, hasChromeFirstChild: { hasChromeFirstChild($0) },
            hasWebAreaDescendant: { hasWebAreaDescendant($0, context: context) }, now: { Date() },
            initialWebAreaDelay: { _ = usleep(100_000) }, sleep: { Thread.sleep(forTimeInterval: $0) },
            webAreaTimedOut: { Logger(subsystem: "local.cua", category: "AXEnablement").log("Timed out waiting for AXWebArea") })
    }
}
