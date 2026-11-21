import AppKit
import ApplicationServices

final class AXAccessibilityTracker {
    final class Lease {
        private let lock = NSLock()
        private var cleanup: (() -> Void)?

        init(_ cleanup: @escaping () -> Void) { self.cleanup = cleanup }

        func release() {
            let action = lock.withLock {
                let action = cleanup
                cleanup = nil
                return action
            }
            action?()
        }

        deinit { release() }
    }

    private struct Entry {
        var count: Int
        let restore: () -> Void
    }

    private let lock = NSLock()
    private struct Key: Hashable {
        let process: String
        let kind: AXAccessibility.Kind
    }
    private var entries: [Key: Entry] = [:]
    private var initializedApplications: Set<String> = []

    func acquire(process: String, kind: AXAccessibility.Kind = .manual, enable: () -> Bool,
                 restore: @escaping () -> Void) -> (Lease, changed: Bool)? {
        let key = Key(process: process, kind: kind)
        return lock.withLock {
            let changed = entries[key] == nil
            if let entry = entries[key] {
                entries[key]?.count = entry.count + 1
            } else {
                guard enable() else { return nil }
                entries[key] = Entry(count: 1, restore: restore)
            }
            return (Lease { self.release(key) }, changed)
        }
    }

    func isInitialized(process: String) -> Bool {
        lock.withLock { initializedApplications.contains(process) }
    }

    func didInitialize(process: String) {
        lock.withLock { _ = initializedApplications.insert(process) }
    }

    func processTerminated(_ process: String) {
        lock.withLock { _ = initializedApplications.remove(process) }
    }

    private func release(_ key: Key) {
        lock.withLock {
            guard let entry = entries[key] else { return }
            if entry.count > 1 {
                entries[key]?.count = entry.count - 1
            } else {
                entries.removeValue(forKey: key)
                entry.restore()
            }
        }
    }
}

enum AXAccessibility {
    enum Kind: String {
        case manual = "AXManualAccessibility"
        case enhanced = "AXEnhancedUserInterface"
    }

    private static let tracker = AXAccessibilityTracker()

    static func kind(supportsManual: Bool, bundle: String, fullContext: Bool) -> Kind? {
        if supportsManual && fullContext { return .manual }
        if fullContext || bundle.hasPrefix("com.apple.iWork") || bundle == "com.spotify.client" { return .enhanced }
        return nil
    }

    static func processTerminated(_ key: String) { tracker.processTerminated(key) }

    static func acquire(for app: ResolvedApp, fullContext: Bool = true) -> AXAccessibilityTracker.Lease? {
        let running = app.running
        let pid = running.processIdentifier
        let process = AppResolver.processKey(running)
        guard pid != getpid(), !running.isTerminated, (try? RequestRuntime.check()) != nil else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 1)
        let attributes = supportedAttributes(application)
        let kind = kind(supportsManual: attributes.contains(Kind.manual.rawValue),
                        bundle: app.bundleIdentifier, fullContext: fullContext)
        let attribute = kind.flatMap { acquireAttribute($0, for: app, application: application, process: process) }
        let voiceOver: (lease: AXAccessibilityTracker.Lease, changed: Bool)?
        if let mode = AXVoiceOverPreference.mode(bundle: app.bundleIdentifier, fullContext: fullContext),
           !running.isTerminated, !Permissions.screenLocked(), (try? RequestRuntime.check()) != nil {
            voiceOver = AXVoiceOverPreference.shared?.acquire(process: process, mode: mode)
        } else {
            voiceOver = nil
        }
        guard attribute != nil || voiceOver != nil else { return nil }
        let lease = AXAccessibilityTracker.Lease {
            attribute?.0.release()
            voiceOver?.lease.release()
        }
        let spotify = kind == .enhanced && app.bundleIdentifier == "com.spotify.client"
        if (attribute?.changed == true || voiceOver?.changed == true), let window = AX.primaryWindow(application),
           (kind == .manual && attribute?.changed == true) ||
           (!tracker.isInitialized(process: process) && (spotify || hasChromeFirstChild(window))) {
            waitForWebArea(window)
            if !running.isTerminated, (try? RequestRuntime.check()) != nil {
                tracker.didInitialize(process: process)
            }
        }
        guard (try? RequestRuntime.check()) != nil else { lease.release(); return nil }
        return lease
    }

    private static func acquireAttribute(_ kind: Kind, for app: ResolvedApp, application: AXUIElement,
                                         process: String) -> (AXAccessibilityTracker.Lease, changed: Bool)? {
        let running = app.running
        let attribute = kind.rawValue as CFString
        let spotify = kind == .enhanced && app.bundleIdentifier == "com.spotify.client"
        let enable = {
            tracker.acquire(process: process, kind: kind, enable: {
                guard boolean(application, attribute: kind.rawValue) == false, !running.isTerminated,
                      (try? RequestRuntime.check()) != nil else { return false }
                let status = AXUIElementSetAttributeValue(application, attribute, kCFBooleanTrue)
                if status == .success { return true }
                // AppKit can apply Enhanced UI before reporting an AX error.
                return kind == .enhanced && boolean(application, attribute: kind.rawValue) == true
            }, restore: {
                guard !running.isTerminated else { return }
                _ = AXUIElementSetAttributeValue(application, attribute, kCFBooleanFalse)
            })
        }
        return spotify && !running.isActive && boolean(application, attribute: kind.rawValue) == false
            ? SyntheticFocusSessions.withTemporaryAccessibilityFocus(app: app, window: AX.primaryWindow(application), operation: enable)
            : enable()
    }

    private static func supportedAttributes(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private static func boolean(_ element: AXUIElement, attribute: String) -> Bool? {
        guard let value = AX.copy(element, attribute), CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value as? Bool
    }

    private static func hasChromeFirstChild(_ window: AXUIElement) -> Bool {
        var raw: CFArray?
        guard AXUIElementCopyAttributeValues(window, kAXChildrenAttribute as CFString, 0, 1, &raw) == .success,
              let child = (raw as? [AnyObject])?.first.flatMap(AX.axElement) else { return false }
        return supportedAttributes(child).contains("ChromeAXNodeId")
    }

    private static func waitForWebArea(_ window: AXUIElement) {
        guard (try? RequestRuntime.wait(0.1)) != nil else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        repeat {
            var pending = [window]
            var visited = Set<AXUIElement>()
            while let element = pending.popLast(), visited.count < 256, ContinuousClock.now < deadline {
                guard (try? RequestRuntime.check()) != nil else { return }
                guard visited.insert(element).inserted else { continue }
                if AX.string(element, kAXRoleAttribute as String) == "AXWebArea" { return }
                pending.append(contentsOf: AX.children(element).reversed())
            }
            guard ContinuousClock.now < deadline, (try? RequestRuntime.wait(0.05)) != nil else { return }
        } while ContinuousClock.now < deadline
    }
}
