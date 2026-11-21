import AppKit
import ApplicationServices

struct AXSettlingActivity<Element: Hashable> {
    var lastChange: Double
    private var titles: [Element: String] = [:]

    init(lastChange: Double) { self.lastChange = lastChange }

    mutating func recordTitle(_ title: String?, for element: Element, at time: Double) {
        guard let title, titles.updateValue(title, forKey: element) != title else { return }
        lastChange = time
    }
}

struct AXSettledWindow {
    static let childLimit = 100
    let processKey: String
    let root: AXReference
    let monitor: EventStreamTreeInvalidationMonitor
    var roles: [AXReference: String] = [:]
    var children: [AXReference: [AXUIElement]] = [:]

    mutating func recordChildren(_ elements: [AXUIElement], returnedCount: Int, for node: AXReference) {
        guard returnedCount < Self.childLimit, elements.count == returnedCount else { return }
        children[node] = elements
    }

    func isCurrent(processKey: String, window: AXUIElement?) -> Bool {
        guard self.processKey == processKey, let window, root == AXReference(element: window), monitor.hasObserver else { return false }
        return monitor.withState { !$0.layoutChanged && $0.destroyedElements.isEmpty }
    }
}

enum AXSettlingInspection {
    case busy
    case ready(AXSettledWindow?)
}

enum AXSettlingBusy {
    static func containsBusyElement<Element: Hashable>(
        in window: Element, music: Bool, role: (Element) -> String?,
        children: (Element) -> [Element], attribute: (Element, String) -> Any?,
        canContinue: () throws -> Bool
    ) throws -> Bool {
        if music, let split = children(window).first(where: { role($0) == "AXSplitGroup" }) {
            for scroll in children(split) where role(scroll) == "AXScrollArea" {
                guard try canContinue() else { return true }
                if children(scroll).allSatisfy({ child in
                    let childRole = role(child)
                    return (childRole == "AXList" || childRole == "AXGroup") && children(child).isEmpty
                }) { return true }
            }
        }

        var pending = [window]
        var seen = Set<Element>()
        while let element = pending.popLast() {
            guard try canContinue() else { return true }
            guard seen.insert(element).inserted else { continue }
            let elementRole = role(element)
            if elementRole == "AXBusyIndicator" { return true }
            // The descendants of a WebArea are still traversed when AXLoaded is unavailable.
            pending.append(contentsOf: children(element).reversed())
            if elementRole == "AXWebArea" {
                guard let loaded = boolValue(attribute(element, "AXLoaded")) else { continue }
                if !loaded { return true }
            }
            if boolValue(attribute(element, "AXElementBusy")) == true { return true }
        }
        return try !canContinue()
    }

    static func inspectWindow(app: AXUIElement, bundle: String, processKey: String,
                              until deadline: Double) throws -> AXSettlingInspection {
        func prepareRead(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(remaining, 1)))
            return true
        }
        func copy(_ element: AXUIElement, _ name: String) -> AnyObject? {
            guard prepareRead(element) else { return nil }
            return AX.copy(element, name)
        }
        let window = AX.axElement(copy(app, kAXFocusedWindowAttribute as String))
            ?? AX.axElement(copy(app, kAXMainWindowAttribute as String))
            ?? (copy(app, kAXWindowsAttribute as String) as? [AnyObject]).flatMap { AX.axElement($0.last) }
        guard let window else { return .busy }
        let root = AXReference(element: window)
        let monitor = EventStreamTreeInvalidationMonitor(application: app)
        var settled = monitor.hasObserver ? AXSettledWindow(processKey: processKey, root: root, monitor: monitor) : nil

        var attributeNames: [AXReference: [String]] = [:]
        var retry = false
        let busy = try containsBusyElement(in: root, music: bundle == "com.apple.Music", role: { node in
            if let role = settled?.roles[node] { return role }
            guard let role = copy(node.element, kAXRoleAttribute as String) as? String else { return nil }
            settled?.roles[node] = role
            return role
        }, children: { node in
            if let children = settled?.children[node] { return children.map { AXReference(element: $0) } }
            guard prepareRead(node.element) else { return [] }
            var values: CFArray?
            let status = AXUIElementCopyAttributeValues(node.element, kAXChildrenAttribute as CFString,
                                                        0, AXSettledWindow.childLimit, &values)
            if status == .cannotComplete || status == .invalidUIElement { retry = true }
            guard status == .success, let values = values as? [AnyObject] else { return [] }
            let children = values.compactMap { AX.axElement($0) }
            settled?.recordChildren(children, returnedCount: values.count, for: node)
            return children.map { AXReference(element: $0) }
        }, attribute: { node, name in
            if attributeNames[node] == nil {
                guard prepareRead(node.element) else { return nil }
                var names: CFArray?
                let status = AXUIElementCopyAttributeNames(node.element, &names)
                if status == .cannotComplete || status == .invalidUIElement { retry = true }
                attributeNames[node] = names as? [String] ?? []
            }
            guard attributeNames[node]?.contains(name) == true else { return nil }
            return copy(node.element, name)
        }, canContinue: {
            try RequestRuntime.check()
            return !retry && ProcessInfo.processInfo.systemUptime < deadline
        })
        if busy { return .busy }
        if let settled, !settled.isCurrent(processKey: processKey, window: window) { return .busy }
        return .ready(settled)
    }
}

/// Observe the target app until it has been quiet, bounded by both the request
/// deadline and a five-second settling cap.
enum AXSettler {
    enum Polling {
        case applicationDefault, tenthSecond

        func interval(isWebShaped: @autoclosure () -> Bool) -> Double {
            self == .applicationDefault && isWebShaped() ? 0.25 : 0.1
        }
    }

    private static let notifications = [kAXTitleChangedNotification, kAXLayoutChangedNotification,
        kAXFocusedWindowChangedNotification, kAXFocusedUIElementChangedNotification,
        kAXElementBusyChangedNotification, kAXMenuOpenedNotification, kAXSheetCreatedNotification,
        kAXWindowCreatedNotification, kAXCreatedNotification, kAXUIElementDestroyedNotification]

    private final class Observation {
        let deduplicateTitles: Bool
        private let lock = NSLock()
        private var activity = AXSettlingActivity<AXReference>(lastChange: ProcessInfo.processInfo.systemUptime)
        var lastChange: Double { lock.withLock { activity.lastChange } }

        init(deduplicateTitles: Bool) { self.deduplicateTitles = deduplicateTitles }

        func restart(at time: Double) { lock.withLock { activity.lastChange = time } }

        func receive(_ name: String, element: AXUIElement) {
            lock.withLock {
                if deduplicateTitles, name == kAXTitleChangedNotification as String {
                    let title = AX.string(element, kAXTitleAttribute as String)
                    activity.recordTitle(title, for: AXReference(element: element), at: ProcessInfo.processInfo.systemUptime)
                } else {
                    activity.lastChange = ProcessInfo.processInfo.systemUptime
                }
            }
        }
    }

    static func waitForNativeCapture(app: ResolvedApp, polling: Polling = .applicationDefault) throws -> AXSettledWindow? {
        try RequestRuntime.check()
        let pid = app.running.processIdentifier
        let element = AXUIElementCreateApplication(pid)
        let interval = polling.interval(isWebShaped: {
            guard let url = app.running.bundleURL, let bundle = Bundle(url: url) else { return false }
            return EventStreamBundleShape.isWebShaped(read: bundle.object(forInfoDictionaryKey:))
        }())
        let state = Observation(deduplicateTitles: true)
        do {
            let observer = try EventStreamNativeAXObserver(pid: pid) { element, notification in
                state.receive(notification, element: element)
            }
            defer { observer.stop() }
            for name in notifications {
                try RequestRuntime.check()
                try observer.register(name as String, for: element, ignoring: .cannotComplete)
            }
            observer.start()
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while true {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                if remaining <= 0 { return nil }
                try RequestRuntime.wait(min(interval, remaining))
                let now = ProcessInfo.processInfo.systemUptime
                if now >= deadline { return nil }
                guard now - state.lastChange >= 0.25 else { continue }
                let result = try AXSettlingBusy.inspectWindow(app: element, bundle: app.bundleIdentifier,
                    processKey: AXCapture.processKey(app), until: deadline)
                try RequestRuntime.check()
                if case .ready(let window) = result, state.lastChange <= now { return window }
            }
        } catch let failure as EventStreamNativeAXObserver.Failure {
            throw ServiceError(.accessibilityError, "Could not observe the target application while settling (\(failure.status.rawValue))")
        }
    }

    static func wait(app: AXUIElement, pid: pid_t, quietPeriod: Double = 0.12,
                     pollingInterval: Double = 0.1, deduplicateTitles: Bool = false) throws {
        try RequestRuntime.check()
        let state = Observation(deduplicateTitles: deduplicateTitles)
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, name, context in
            guard let context else { return }
            Unmanaged<Observation>.fromOpaque(context).takeUnretainedValue().receive(name as String, element: element)
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else {
            try RequestRuntime.wait(quietPeriod)
            return
        }
        let names = notifications + [kAXValueChangedNotification]
        var elements = [app]
        if let windows = AX.copy(app, kAXWindowsAttribute as String) as? [AnyObject] {
            elements += windows.compactMap { AX.axElement($0) }
        }
        let context = Unmanaged.passUnretained(state).toOpaque()
        var registrations: [(AXUIElement, String)] = []
        for element in elements {
            for name in names {
                if AXObserverAddNotification(observer, element, name as CFString, context) == .success {
                    registrations.append((element, name))
                }
            }
        }
        let loop = CFRunLoopGetCurrent()
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(loop, source, .defaultMode)
        defer {
            for (element, name) in registrations { AXObserverRemoveNotification(observer, element, name as CFString) }
            CFRunLoopRemoveSource(loop, source, .defaultMode)
            withExtendedLifetime(state) {}
        }
        if registrations.isEmpty { try RequestRuntime.wait(quietPeriod); return }
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + 5
        state.restart(at: start)
        while true {
            try RequestRuntime.check()
            let now = ProcessInfo.processInfo.systemUptime
            if now >= deadline || now - state.lastChange >= quietPeriod { return }
            CFRunLoopRunInMode(.defaultMode, min(pollingInterval, 0.01), false)
        }
    }
}
