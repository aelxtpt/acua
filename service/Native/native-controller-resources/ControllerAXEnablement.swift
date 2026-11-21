import Foundation

enum ControllerAXEnablementKind: UInt8, Hashable, Sendable { case manual, enhanced, voiceOver }

/// Native keys use NSObject equality/hash for NSRunningApplication, not PID or
/// an invented process-string key. Native operations execute outside this lock.
final class ControllerAXEnablementTracker<Application: Hashable & Sendable>: @unchecked Sendable {
    struct Key: Hashable, Sendable { let application: Application; let kind: ControllerAXEnablementKind }
    private let lock = NSLock()
    private var counts: [Key: Int] = [:]
    private var initialized: [Application] = []
    let invalidRelease: @Sendable (Application, ControllerAXEnablementKind) -> Void
    init(invalidRelease: @escaping @Sendable (Application, ControllerAXEnablementKind) -> Void) { self.invalidRelease = invalidRelease }
    func acquire(_ app: Application, _ kind: ControllerAXEnablementKind) -> Bool {
        lock.withLock {
            let key = Key(application: app, kind: kind), old = counts[key, default: 0]
            counts[key] = old + 1
            return old == 0
        }
    }
    func release(_ app: Application, _ kind: ControllerAXEnablementKind) -> Bool {
        let result: Bool? = lock.withLock {
            let key = Key(application: app, kind: kind)
            guard let old = counts[key], old > 0 else { return nil }
            if old == 1 { counts.removeValue(forKey: key); return true }
            counts[key] = old - 1; return false
        }
        if let result { return result }
        invalidRelease(app, kind); return false
    }
    func isInitialized(_ app: Application) -> Bool { lock.withLock { initialized.contains(app) } }
    func markInitialized(_ app: Application) { lock.withLock { initialized.append(app) } }
    func applicationTerminated(_ app: Application) {
        lock.withLock {
            initialized.removeAll { $0 == app }
            counts = counts.filter { $0.key.application != app }
        }
    }
}

final class ControllerAXEnablementAssertion: @unchecked Sendable {
    let kinds: [ControllerAXEnablementKind]
    private let lock = NSLock()
    private var enabled = true
    private let cleanup: @Sendable ([ControllerAXEnablementKind]) -> Void
    init(kinds: [ControllerAXEnablementKind], cleanup: @escaping @Sendable ([ControllerAXEnablementKind]) -> Void) {
        self.kinds = kinds; self.cleanup = cleanup
    }
    var isEnabled: Bool { lock.withLock { enabled } }
    func disable() {
        let perform = lock.withLock { let old = enabled; enabled = false; return old }
        if perform { cleanup(kinds) }
    }
    deinit { disable() }
}

struct ControllerAXEnablement<Application: Hashable & Sendable, Node: Sendable, Focus: Sendable>: Sendable {
    struct Preferences: Sendable {
        let read: @Sendable () -> Bool
        let write: @Sendable (Bool) -> Void
    }
    struct Environment: Sendable {
        let resolveApplication: @Sendable (Node) -> (Application, String)?
        let supportsManual: @Sendable (Node) -> Bool
        let boolean: @Sendable (Node, String) -> Bool?
        let setBoolean: @Sendable (Node, String, Bool) throws -> Void
        let isActive: @Sendable (Application) -> Bool
        let makeFocus: @Sendable (Application) -> Focus
        let enforceFocus: @Sendable (Focus, Node?) throws -> Void
        let deactivateFocus: @Sendable (Focus) throws -> Void
        let makePreferences: @Sendable () -> Preferences?
        let notifyPreferences: @Sendable () -> Void
        let voiceOverApplicationExists: @Sendable () -> Bool
        let schedulePulse: @Sendable (Preferences) -> Void
        let hasChromeFirstChild: @Sendable (Node) -> Bool
        let hasWebAreaDescendant: @Sendable (Node) -> Bool
        let now: @Sendable () -> Date
        let initialWebAreaDelay: @Sendable () -> Void
        let sleep: @Sendable (TimeInterval) -> Void
        let webAreaTimedOut: @Sendable () -> Void
    }
    let tracker: ControllerAXEnablementTracker<Application>
    let environment: Environment

    static func baseKind(supportsManual: Bool, bundle: String, context: UInt8) -> ControllerAXEnablementKind? {
        if supportsManual && context == 0 { return .manual }
        if context == 0 || bundle.hasPrefix("com.apple.iWork") || bundle == "com.spotify.client" { return .enhanced }
        return nil
    }
    static func voiceOverSelected(bundle: String, context: UInt8) -> Bool {
        bundle == "com.microsoft.Excel" || bundle == "com.apple.Music" ||
            (context == 0 && ["company.thebrowser.Browser", "company.thebrowser.dia"].contains(bundle))
    }
    static func voiceOverPulses(bundle: String) -> Bool {
        ["company.thebrowser.Browser", "company.thebrowser.dia"].contains(bundle)
    }

    func acquire(application node: Node, window: Node?, context: UInt8) -> ControllerAXEnablementAssertion? {
        guard let (app, bundle) = environment.resolveApplication(node) else { return nil }
        var kinds: [ControllerAXEnablementKind] = []
        var changed = false
        if let kind = Self.baseKind(supportsManual: environment.supportsManual(node), bundle: bundle, context: context) {
            kinds.append(kind)
            if tracker.acquire(app, kind) {
                let attribute = kind == .manual ? "AXManualAccessibility" : "AXEnhancedUserInterface"
                if environment.boolean(node, attribute) == false {
                    var focus: Focus?
                    if kind == .manual { changed = true }
                    if kind == .enhanced && bundle == "com.spotify.client" {
                        changed = true
                        if !environment.isActive(app) {
                            let created = environment.makeFocus(app); focus = created
                            try? environment.enforceFocus(created, window)
                            let start = environment.now()
                            while environment.now().timeIntervalSince(start) <= 1 {
                                if environment.isActive(app) { break }
                                environment.sleep(0.05)
                            }
                        }
                    }
                    // Manual/enhanced helpers claim the attempt even when the
                    // native setter fails. They do not re-read or roll back it.
                    try? environment.setBoolean(node, attribute, true)
                    if let focus { try? environment.deactivateFocus(focus) }
                } else {
                    _ = tracker.release(app, kind)
                }
            }
        }
        if Self.voiceOverSelected(bundle: bundle, context: context) {
            kinds.append(.voiceOver)
            if tracker.acquire(app, .voiceOver) {
                if let prefs = environment.makePreferences(), !prefs.read() {
                    prefs.write(true); environment.notifyPreferences()
                    if Self.voiceOverPulses(bundle: bundle) { environment.schedulePulse(prefs) }
                } else { _ = tracker.release(app, .voiceOver) }
            }
        }
        if changed || window.map(environment.hasChromeFirstChild) == true {
            if kinds.contains(.manual) || !tracker.isInitialized(app) {
                if let window, waitForWebArea(window) { tracker.markInitialized(app) }
            }
        }
        guard !kinds.isEmpty else { return nil }
        // A kind remains in the assertion even after a failed first acquire
        // rolls its count back, so a later release still covers it.
        return .init(kinds: kinds) { retained in
            // The assertion retains the complete operation, including
            // its optional window, even after explicit disable.
            withExtendedLifetime((window, bundle, context)) {
            for kind in retained where tracker.release(app, kind) {
                switch kind {
                case .manual: try? environment.setBoolean(node, "AXManualAccessibility", false)
                case .enhanced: try? environment.setBoolean(node, "AXEnhancedUserInterface", false)
                case .voiceOver:
                    if !environment.voiceOverApplicationExists(), let prefs = environment.makePreferences() {
                        prefs.write(false); environment.notifyPreferences()
                    }
                }
            }
            }
        }
    }

    private func waitForWebArea(_ window: Node) -> Bool {
        environment.initialWebAreaDelay()
        let start = environment.now()
        while environment.now().timeIntervalSince(start) <= 1 {
            if environment.hasWebAreaDescendant(window) { return true }
            environment.sleep(0.05)
        }
        environment.webAreaTimedOut(); return false
    }
}
