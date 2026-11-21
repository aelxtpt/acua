import Foundation

struct ControllerUISettleOptions: Sendable {
    var delay: Double? = nil
    var notificationDelay: Double = 0.25
    var includingScrollEvents = false
}
enum ControllerUISettleLog: String, Sendable {
    case started = "3c15969ba22c99c5bf09"
    case cancelled = "432d5e9ec5543dc4657c"
    case timeout = "716d5a15344645c5c45a"
    case polling = "7450393007154c78617a"
    case quietAge = "62fb6b64f8c79350432d"
    case ready = "1391acbbe32570317f6f"
}

/// Hold the lock while reading a title and comparing/updating it.
/// Nil/non-string/unreadable titles do not count as activity.
final class ControllerUISettleActivity<Key: Hashable & Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var lastChange: Double
    private var titles: [Key: String] = [:]
    init(now: Double) { lastChange = now }
    @discardableResult func receive(_ notification: String, key: Key, title: () -> String?, now: () -> Double) -> Bool {
        lock.withLock {
            if notification == "AXTitleChanged" {
                guard let title = title() else { return false }
                let previous = titles.updateValue(title, forKey: key)
                if previous == title { return false }
            }
            lastChange = now()
            return true
        }
    }
    func quietAge(now: () -> Double) -> Double { lock.withLock { now() - lastChange } }
}

@MainActor protocol ControllerUISettleBackend {
    associatedtype Window
    associatedtype Cache
    associatedtype Observation
    var isCancelled: Bool { get }
    func isWebShaped() -> Bool
    func now() -> Double
    func observe(_ notifications: [String]) throws -> Observation
    func stop(_ observation: Observation)
    func quietAge(_ observation: Observation) async -> Double
    func sleep(_ seconds: Double) async throws
    func focusedWindow() -> Window?
    func mainWindow() -> Window?
    func windows() -> [Window]
    func inspect(_ window: Window) async throws -> (busy: Bool, cache: Cache)
    func log(_ event: ControllerUISettleLog, value: Double?)
}

/// Waits for the UI to settle. The five-second cap and activity use CF wall time;
/// polling sleeps use ContinuousClock. A ready inspection returns its cache
/// immediately, without an added cancellation/deadline/quiet-state recheck.
@MainActor struct ControllerUISettle<Backend: ControllerUISettleBackend> {
    static var notifications: [String] { ["AXTitleChanged", "AXLayoutChanged", "AXFocusedWindowChanged", "AXFocusedUIElementChanged",
        "AXElementBusyChanged", "AXMenuOpened", "AXSheetCreated", "AXWindowCreated", "AXCreated", "AXUIElementDestroyed"] }
    let backend: Backend
    func wait(_ options: ControllerUISettleOptions = .init()) async throws -> Backend.Cache? {
        let interval = options.delay ?? (backend.isWebShaped() ? 0.25 : 0.1)
        var notifications = Self.notifications
        if options.includingScrollEvents { notifications.append("AXValueChanged") }
        backend.log(.started, value: nil)
        let observation = try backend.observe(notifications)
        defer { backend.stop(observation) }
        let start = backend.now()
        while true {
            if backend.isCancelled { backend.log(.cancelled, value: nil); return nil }
            if backend.now() - start >= 5 { backend.log(.timeout, value: 5); return nil }
            backend.log(.polling, value: interval)
            try await backend.sleep(interval)
            let quiet = await backend.quietAge(observation)
            backend.log(.quietAge, value: quiet)
            if quiet >= options.notificationDelay {
                if let window = backend.focusedWindow() ?? backend.mainWindow() ?? backend.windows().last {
                    let result = try await backend.inspect(window)
                    if !result.busy { backend.log(.ready, value: nil); return result.cache }
                }
            }
        }
    }
}

@MainActor protocol ControllerUISettleBusyBackend {
    associatedtype Node
    func role(_ node: Node) -> String
    func children(_ node: Node) -> [Node]
    func loaded(_ node: Node) -> Bool?
    func supports(_ name: String, _ node: Node) -> Bool
    func elementBusy(_ node: Node) -> Bool?
    func classes(_ node: Node) -> [String]?
}

@MainActor struct ControllerUISettleBusy<Backend: ControllerUISettleBusyBackend> {
    let backend: Backend
    func inspect(_ nodes: [Backend.Node], window: Backend.Node, bundle: String?) -> Bool {
        if bundle == "com.apple.Music", musicIsEmpty(window) { return true }
        for node in nodes {
            let role = backend.role(node)
            if role == "AXBusyIndicator" { return true }
            if role == "AXWebArea" {
                // Skip the other two predicates for a WebArea
                // whose AXLoaded getter is nil/error/unsupported.
                guard let loaded = backend.loaded(node) else { continue }
                if !loaded { return true }
            }
            if backend.supports("AXElementBusy", node), backend.elementBusy(node) == true { return true }
        }
        return false
    }
    private func musicIsEmpty(_ window: Backend.Node) -> Bool {
        guard let split = backend.children(window).first(where: { backend.role($0) == "AXSplitGroup" }) else { return false }
        for scroll in backend.children(split) where backend.role(scroll) == "AXScrollArea" {
            if backend.children(scroll).allSatisfy({ child in
                let role = backend.role(child)
                return (role == "AXList" || role == "AXGroup") && backend.children(child).isEmpty
            }) { return true }
        }
        return false
    }
}
