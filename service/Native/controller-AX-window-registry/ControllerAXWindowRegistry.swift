import Foundation

/// Per-controller registry. Callbacks use the serial observer path;
/// individual stores are locked for Swift sharing, without an epoch,
/// active-state or process-instance guard.
final class ControllerAXWindowRegistry<Node: Sendable>: @unchecked Sendable {
    enum Kind: Sendable { case window, sheet, menu }
    enum Notification: String, Sendable {
        case windowCreated = "AXWindowCreated", elementDestroyed = "AXUIElementDestroyed"
        case menuOpened = "AXMenuOpened", menuClosed = "AXMenuClosed", sheetCreated = "AXSheetCreated"
        case windowMoved = "AXMoved", windowResized = "AXResized"
    }
    struct Entry: Sendable { let node: Node; let kind: Kind }
    struct Observation: Sendable {
        let registerDestroyed: @Sendable (Node) throws -> Void
        let removeDestroyed: @Sendable (Node) throws -> Void
    }
    struct Environment: Sendable {
        let primaryWindow: @Sendable () -> Node?
        let children: @Sendable (Node) -> [Node]
        let role: @Sendable (Node) -> String?
        let windowID: @Sendable (Node) throws -> UInt32
        let menuWindowID: @Sendable (Node) throws -> UInt32
        let actualPID: @Sendable (Node) throws -> Int32
        let sameElement: @Sendable (Node, Node) -> Bool
        let publishOrderingIDs: @Sendable ([UInt32]) -> Void
        let clearApplicationAttention: @Sendable () -> Void
        let setOpenedMenu: @Sendable (Node?) -> Void
        let setFocusedMenuBarItem: @Sendable (Node?) -> Void
        let menuDidOpen: @Sendable () -> Void
        let menuDidClose: @Sendable () -> Void
        let setFocusEnforcerPID: @Sendable (Int32?) -> Void
        let clearFocusEnforcerPID: @Sendable () -> Void
        let now: @Sendable () -> Date
        let sleep: @Sendable (TimeInterval) -> Void
    }
    private let lock = NSLock()
    private var stored: [UInt32: Entry] = [:]
    private var observation: Observation?
    let bundleIdentifier: String
    let environment: Environment

    init(bundleIdentifier: String, environment: Environment) {
        self.bundleIdentifier = bundleIdentifier; self.environment = environment
    }
    func setObservation(_ observation: Observation?) { lock.withLock { self.observation = observation } }
    func snapshot() -> [UInt32: Entry] { lock.withLock { stored } }
    private func publish() { environment.publishOrderingIDs(Array(snapshot().keys)) }

    private func track(_ node: Node, kind: Kind) {
        let id: UInt32
        do { id = try kind == .menu ? environment.menuWindowID(node) : environment.windowID(node) }
        catch { return }
        lock.withLock { stored[id] = Entry(node: node, kind: kind) }
        publish()
    }

    /// Only descendants whose own role is AXSheet are traversed further.
    func seed() {
        if let primary = environment.primaryWindow() {
            track(primary, kind: .window)
            var queue = environment.children(primary)
            while !queue.isEmpty {
                let next = queue.removeFirst()
                guard environment.role(next) == "AXSheet" else { continue }
                track(next, kind: .sheet)
                queue.append(contentsOf: environment.children(next))
            }
        }
        publish()
    }

    /// Calls the RAW AX window-ID getter and retains nonzero IDs.
    /// For menus this is the anchor, not the custom menu-window key in stored.
    func windows() -> [UInt32: Entry] {
        let filtered = snapshot().filter { _, entry in
            guard let id = try? environment.windowID(entry.node) else { return false }
            return id != 0
        }
        let changed = lock.withLock {
            guard filtered.count != stored.count else { return false }
            stored = filtered
            return true
        }
        if changed { publish() }
        return snapshot()
    }

    func receive(_ notification: Notification, element: Node) {
        switch notification {
        case .windowCreated:
            track(element, kind: .window)
            environment.clearApplicationAttention()
            guard bundleIdentifier == "com.apple.controlcenter" else { return }
            if let observation = lock.withLock({ observation }) { try? observation.registerDestroyed(element) }
            environment.setFocusEnforcerPID(try? environment.actualPID(element))
        case .elementDestroyed:
            if let observation = lock.withLock({ observation }) { try? observation.removeDestroyed(element) }
            // No direct dictionary removal or ordering publication in this branch.
            environment.clearFocusEnforcerPID()
        case .menuOpened:
            environment.setOpenedMenu(element)
            _ = try? ControllerSynchronousPoll.untilNotNil(timeout: 0.25, delay: 0.01,
                now: environment.now, sleep: environment.sleep) { try? environment.menuWindowID(element) }
            // Even a successful poll result is discarded; the getter runs again.
            track(element, kind: .menu)
            environment.menuDidOpen()
            environment.setFocusEnforcerPID(try? environment.actualPID(element))
        case .menuClosed:
            environment.menuDidClose()
            environment.setOpenedMenu(nil)
            environment.setFocusedMenuBarItem(nil)
            let keys = snapshot().filter { environment.sameElement($0.value.node, element) }.map(\.key)
            for key in keys {
                _ = lock.withLock { stored.removeValue(forKey: key) }
                publish()
            }
            environment.clearFocusEnforcerPID()
        case .sheetCreated:
            track(element, kind: .sheet)
            environment.clearApplicationAttention()
        case .windowMoved, .windowResized:
            publish()
        }
    }
}

enum ControllerSynchronousPoll {
    struct Timeout: Error {}
    /// Uses Date, a strict greater-than timeout and blocking Thread sleep.
    static func untilNotNil<T>(timeout: TimeInterval, delay: TimeInterval,
        now: () -> Date, sleep: (TimeInterval) -> Void, condition: () -> T?) throws -> T {
        let start = now()
        while true {
            guard !(now().timeIntervalSince(start) > timeout) else { throw Timeout() }
            if let result = condition() { return result }
            sleep(delay)
        }
    }
}
