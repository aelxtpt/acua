import Foundation

protocol ControllerFocusObservation: AnyObject, Sendable { func remove() }
protocol ControllerFocusTracking: AnyObject, Sendable {
    func observe(_ handler: @escaping @Sendable (Int32) -> Void) -> any ControllerFocusObservation
}
protocol ControllerFocusTap<Event>: AnyObject, Sendable {
    associatedtype Event: Sendable
    func start(_ handler: @escaping @Sendable (UInt32, Event) -> Event?)
    func stop()
}

struct ControllerFocusTapConfiguration: Sendable, Equatable {
    enum Location: Sendable, Equatable { case process(Int32), annotatedSession }
    let location: Location
    let types: [UInt32]
    let tail: Bool
    let listenOnly: Bool
}
enum ControllerFocusPacket: Sendable, Equatable {
    case activation(windowID: UInt32, frame: CGRect?, point: CGPoint?)
    case keyFocusReturned
    case deactivation
}
struct ControllerFocusWindow: Sendable {
    let id: UInt32
    let pid: Int32
    let layer: Int
}

/// Nonactor, reusable focus resource.
/// Native I/O is required explicitly; no legacy focus lease is substituted.
final class ControllerSyntheticFocus<Application: Sendable, Window: Sendable, Event: Sendable>: @unchecked Sendable {
    struct State: Sendable, Equatable {
        var believesActive = false
        var believesFocused = false
        var actuallyActive = false
    }
    enum Failure: Error, Equatable { case couldNotActivatePrevious, foregroundChanged, timeout }
    struct Environment: Sendable {
        let makeTracker: @Sendable () -> any ControllerFocusTracking
        let makeTap: @Sendable (ControllerFocusTapConfiguration) -> any ControllerFocusTap<Event>
        let registerPrevention: @Sendable (Int32, @escaping @Sendable () -> Void, @escaping @Sendable () -> Void) -> Void
        let unregisterPreventionIfPresent: @Sendable (Int32) -> Void
        let currentlyFocused: @Sendable (Int32) -> Bool
        let isActive: @Sendable (Int32) -> Bool
        let integer: @Sendable (Event, UInt32) -> Int64
        let subtypeField: UInt32?
        let windowUnderPointerField: UInt32?
        let resignedKeySubtype: Int16?
        let resignedMainSubtype: Int16?
        let processIdentifier: @Sendable () -> Int32
        let windowOwner: @Sendable (UInt32) -> Int32?
        let activatePID: @Sendable (Int32) -> Void
        let post: @Sendable (Event, Int32) -> Void
        // The outer optional is attribute availability. A present nil CGPoint
        // still resolves windowID/frame and builds the window activation packet.
        let activationPoint: @Sendable (Window) -> CGPoint??
        let windowID: @Sendable (Window) throws -> UInt32
        let frame: @Sendable (Window) -> CGRect?
        let send: @Sendable (ControllerFocusPacket, Int32) throws -> Void
        let startMenuSuppressionIfPresent: @Sendable (Int32, Int32?) -> Void
        let stopMenuSuppressionIfPresent: @Sendable (Int32) -> Void
        let recordSynthesizedAction: @Sendable (Double, Int32, Bool) -> Void
        let uptime: @Sendable () -> Double
        let frontmost: @Sendable () -> Application?
        let pid: @Sendable (Application) -> Int32
        let focusedWindow: @Sendable (Application) throws -> Window?
        let activate: @Sendable (Application) -> Bool
        let targetBelievesFrontmost: @Sendable (Int32) -> Bool?
        let waitUntilTargetBelievesFrontmost: @Sendable (Int32, Double) async -> Void
        let windows: @Sendable () -> [ControllerFocusWindow]
        let raise: @Sendable (Window) throws -> Void
        let mainConnection: @Sendable () -> UInt
        let disableUpdates: @Sendable (UInt) -> Void
        let reenableUpdates: @Sendable (UInt) -> Void
        let checkCancellation: @Sendable () throws -> Void
        let sleep: @Sendable (Duration) async throws -> Void
    }

    let pid: Int32
    private let environment: Environment
    private let tracker: any ControllerFocusTracking
    private var observation: (any ControllerFocusObservation)?
    private let stateLock = NSLock()
    private var stored = State()
    private var clickTap: (any ControllerFocusTap<Event>)?
    private let activationTap: any ControllerFocusTap<Event>
    private let suppressionLock = NSLock()
    private var suppression: (@Sendable (UInt32, Event) -> Bool)?

    init(pid: Int32, environment: Environment) {
        tracker = environment.makeTracker()
        self.pid = pid; self.environment = environment
        activationTap = environment.makeTap(.init(location: .process(pid), types: [13, 19, 20], tail: true, listenOnly: false))
        environment.registerPrevention(pid, { [weak self] in self?.mutate { $0.believesFocused = false } },
            { [weak self] in self?.mutate { $0.believesFocused = true } })
        let active = environment.isActive(pid)
        mutate { $0 = .init(believesActive: active, believesFocused: environment.currentlyFocused(pid), actuallyActive: active) }
        activationTap.start { [weak self] type, event in
            guard let self else { return event }
            return self.receive(type, event)
        }
        observation = tracker.observe { [weak self] frontmostPID in
            guard let self else { return }
            self.mutate { $0.actuallyActive = frontmostPID == pid }
        }
    }
    var state: State { stateLock.withLock { stored } }

    /// Click monitoring follows active && !actuallyActive, under the
    /// same lock as the state mutation. Focused alone does not change that tap.
    private func mutate(_ body: (inout State) -> Void) {
        stateLock.withLock {
            let previous = stored.believesActive && !stored.actuallyActive
            body(&stored)
            let next = stored.believesActive && !stored.actuallyActive
            guard previous != next else { return }
            if next {
                let tap = environment.makeTap(.init(location: .annotatedSession, types: [1], tail: false, listenOnly: true))
                tap.start { [weak self] _, event in
                    guard let self else { return event }
                    return self.receiveClick(event)
                }
                clickTap = tap
            } else {
                clickTap?.stop(); clickTap = nil
            }
        }
    }
    private func subtype(_ event: Event) -> Int16? {
        environment.subtypeField.flatMap { Int16(exactly: environment.integer(event, $0)) }
    }
    private func receive(_ type: UInt32, _ event: Event) -> Event? {
        if suppressionLock.withLock({ suppression?(type, event) ?? false }) { return nil }
        let subtype = subtype(event)
        if type == 20 || (type == 13 && subtype == 1) {
            mutate { $0.believesActive = true; $0.believesFocused = true }
        } else if type == 19 || (type == 13 && subtype == 2) {
            mutate { $0.believesActive = false; $0.believesFocused = false }
        }
        return event
    }
    private func receiveClick(_ event: Event) -> Event {
        // Conversions trap on out-of-range native fields.
        guard Int32(environment.integer(event, 41)) != environment.processIdentifier(),
              Int32(environment.integer(event, 40)) != pid,
              let field = environment.windowUnderPointerField,
              let owner = environment.windowOwner(UInt32(environment.integer(event, field))), owner == pid else { return event }
        environment.activatePID(owner)
        return event
    }
    func enforceActiveState(for window: Window?) throws {
        let initial = state
        if initial.believesFocused { return }
        if initial.believesActive {
            try environment.send(.keyFocusReturned, pid)
            mutate { $0.believesFocused = true }
        } else {
            let packet: ControllerFocusPacket
            if let window, let point = environment.activationPoint(window), let id = try? environment.windowID(window) {
                packet = .activation(windowID: id, frame: environment.frame(window), point: point)
            } else { packet = .activation(windowID: 0, frame: nil, point: nil) }
            try environment.send(packet, pid)
            mutate { $0.believesActive = true; $0.believesFocused = true }
        }
    }
    func deactivateFocusEnforcer() throws {
        let initial = state
        guard initial.believesActive && !initial.actuallyActive else { return }
        try environment.send(.deactivation, pid)
        mutate { $0.believesActive = false; $0.believesFocused = false }
    }
    func startSuppressingMenuDismissalEvents(menuPID: Int32?) { environment.startMenuSuppressionIfPresent(pid, menuPID) }
    func stopSuppressingMenuDismissalEvents() { environment.stopMenuSuppressionIfPresent(pid) }
    func synthesizedActionWasPerformed() { environment.recordSynthesizedAction(environment.uptime(), pid, false) }

    private final class RestoreState: @unchecked Sendable {
        struct Snapshot {
            var sawTransition = false
            var previousActivated = false
            var targetDeactivated = false
            var lastEvent: Double
        }
        let lock = NSLock()
        var value: Snapshot
        init(_ time: Double) { value = .init(lastEvent: time) }
        var snapshot: Snapshot { lock.withLock { value } }
        func resetNotices(_ time: Double) {
            lock.withLock { value.previousActivated = false; value.targetDeactivated = false; value.lastEvent = time }
        }
        func touch(_ time: Double) { lock.withLock { value.lastEvent = time } }
    }
    /// Preserve foreground and stacking without borrowing the
    /// legacy global restoration lock, process-key guards or AX correction loop.
    func safelyEnforceActiveState(for window: Window?) async throws {
        guard let previous = environment.frontmost(), environment.pid(previous) != pid else {
            try enforceActiveState(for: window)
            await environment.waitUntilTargetBelievesFrontmost(pid, 0.25)
            return
        }
        let previousPID = environment.pid(previous)
        let focused = try? environment.focusedWindow(previous)
        let focusedID = focused.flatMap { try? environment.windowID($0) }
        let restore = RestoreState(environment.uptime())
        let previousTap = environment.makeTap(.init(location: .process(previousPID), types: [13, 19, 20], tail: false, listenOnly: false))
        let environment = self.environment
        let targetPID = pid
        let subtype: @Sendable (Event) -> Int16? = { event in
            environment.subtypeField.flatMap { Int16(exactly: environment.integer(event, $0)) }
        }
        let resigned: @Sendable (UInt32, Int16?) -> Bool = { type, subtype in
            type == 13 && (subtype == environment.resignedKeySubtype || subtype == environment.resignedMainSubtype)
        }
        previousTap.start { type, event in
            restore.lock.withLock {
                restore.value.lastEvent = environment.uptime()
                let subtype = subtype(event)
                if type == 20 || (type == 13 && subtype == 1) {
                    restore.value.sawTransition = true; restore.value.previousActivated = true
                    return nil
                }
                if type == 19 || (type == 13 && subtype == 2) {
                    restore.value.sawTransition = true; return nil
                }
                return resigned(type, subtype) ? nil : event
            }
        }
        let servicePID = environment.processIdentifier()
        let keyboardTap = environment.makeTap(.init(location: .process(pid), types: [10, 11, 12], tail: false, listenOnly: false))
        keyboardTap.start { _, event in
            if Int32(environment.integer(event, 41)) != servicePID && Int32(environment.integer(event, 40)) == targetPID {
                environment.post(event, previousPID); return nil
            }
            return event
        }
        suppressionLock.withLock {
            suppression = { type, event in
                restore.lock.withLock {
                    restore.value.lastEvent = environment.uptime()
                    let subtype = subtype(event)
                    if type == 20 { restore.value.sawTransition = true; return false }
                    if type == 19 || (type == 13 && subtype == 2) {
                        restore.value.sawTransition = true; restore.value.targetDeactivated = true; return true
                    }
                    return resigned(type, subtype)
                }
            }
        }
        let connection = environment.mainConnection()
        environment.disableUpdates(connection)
        defer {
            environment.reenableUpdates(connection)
            suppressionLock.withLock { suppression = nil }
            keyboardTap.stop(); previousTap.stop()
        }
        var initialError: (any Error)?
        do { try enforceActiveState(for: window) } catch { initialError = error }
        restore.touch(environment.uptime())
        let start = environment.uptime()
        var lastActivationAttempt = 0.0
        var activationAttempted = false
        var waitForNoticesOnError = false
        do {
            while true {
                try environment.checkCancellation()
                let now = environment.uptime()
                let elapsed = now - start
                let current = environment.frontmost().map(environment.pid)
                if current == pid {
                    if now - lastActivationAttempt >= 0.05 {
                        restore.resetNotices(now)
                        guard environment.activate(previous) else { throw Failure.couldNotActivatePrevious }
                        activationAttempted = true; waitForNoticesOnError = true
                        lastActivationAttempt = now
                    }
                } else {
                    guard current == previousPID else { throw Failure.foregroundChanged }
                    let believes = initialError != nil || environment.targetBelievesFrontmost(pid) == true
                    if let focusedID {
                        let windows = environment.windows()
                        if let index = windows.firstIndex(where: { $0.id == focusedID }),
                           windows[..<index].contains(where: { $0.pid == pid && $0.layer == windows[index].layer }) {
                            if let focused { try environment.raise(focused) }
                            restore.touch(now)
                            if elapsed < 1 {
                                try await environment.sleep(.milliseconds(10)); continue
                            }
                        }
                    }
                    if believes || elapsed >= 1 {
                        let current = environment.frontmost().map(environment.pid)
                        let flags = restore.snapshot
                        let waitForNotices = initialError != nil ? waitForNoticesOnError : activationAttempted
                        if current == previousPID {
                            if waitForNotices && (!flags.previousActivated || !flags.targetDeactivated) {
                                waitForNoticesOnError = true
                            } else if !(initialError != nil || activationAttempted || flags.sawTransition)
                                        || environment.uptime() - flags.lastEvent >= 0.1 {
                                if let initialError { throw initialError }
                                return
                            }
                        }
                    }
                }
                guard elapsed < 2 else { throw Failure.timeout }
                try await environment.sleep(.milliseconds(10))
            }
        } catch { throw initialError ?? error }
    }

    deinit {
        observation?.remove()
        environment.unregisterPreventionIfPresent(pid)
        // Resource destruction owns tap teardown; deactivation is not implied.
    }
}
