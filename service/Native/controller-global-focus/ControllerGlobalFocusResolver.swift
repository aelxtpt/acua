import Foundation

struct ControllerGlobalFocusObservation: Sendable {
    let queryStatus: Int32
    let processStatus: Int32
    let pid: Int32
    let flag: Bool
}

/// Resolves global focus changes. Preserve ordinary vs actual PID.
struct ControllerGlobalFocusResolver<Node: Sendable>: Sendable {
    typealias Focus = ControllerKeyboardFocusState.Focus
    typealias Observation = ControllerGlobalFocusObservation
    struct Environment: Sendable {
        let query: @Sendable () -> Observation?
        let bridgePID: @Sendable () -> Int32?
        // nil means no NSRunningApplication; 2 means prohibited/service.
        let policy: @Sendable (Int32) -> Int?
        let frontmostPID: @Sendable () -> Int32?
        let application: @Sendable (Int32) -> Node
        let focused: @Sendable (Node) -> Node?
        let focusedWindow: @Sendable (Node) -> Node?
        let mainWindow: @Sendable (Node) -> Node?
        let ordinaryPID: @Sendable (Node) throws -> Int32
        let actualPID: @Sendable (Node) throws -> Int32
        let nameHostPID: @Sendable (Int32) -> Int32?
        let synthesizedAction: @Sendable () -> (Double, Int32, Bool)
        let uptime: @Sendable () -> Double
        let sleepMicroseconds: @Sendable (UInt32) -> Void
    }
    let environment: Environment

    func current() -> Focus {
        guard let observation = environment.query() else { return .regular(environment.frontmostPID() ?? 0) }
        let raw: Int32?
        if observation.processStatus == -600 && observation.queryStatus == 0 && !observation.flag,
           let bridge = environment.bridgePID(), environment.policy(bridge) == nil {
            raw = bridge
        } else { raw = observation.queryStatus == 0 && observation.processStatus == 0 ? observation.pid : nil }
        guard let raw else { return .regular(environment.frontmostPID() ?? 0) }
        return resolve(raw)
    }
    func resolve(_ raw: Int32) -> Focus {
        if environment.bridgePID() == raw {
            let app = environment.application(raw)
            let owner = auxiliaryHost(app)
            let service: Int32?
            if let focused = environment.focused(app), let pid = try? environment.actualPID(focused) {
                let policy = environment.policy(pid)
                service = policy == nil || policy == 2 ? pid : nil
            } else { service = nil }
            return .viewService(app:owner,service:service)
        }
        guard environment.policy(raw) == 2 else { return .regular(raw) }
        let app = environment.application(raw)
        return .viewService(app:host(application:app,focused:nil,allowNameFallback:true),service:raw)
    }
    private func auxiliaryHost(_ app: Node) -> Int32 {
        if let focused = environment.focused(app) { return host(application:app,focused:focused,allowNameFallback:false) }
        if !(environment.uptime() - environment.synthesizedAction().0 >= 1) {
            var focused: Node?
            // Twelve sleeps, not an elapsed-time loop; attribute snapshots and
            // the latest action flag/PID stay authoritative throughout.
            for _ in 0..<12 {
                environment.sleepMicroseconds(15000)
                focused = environment.focused(app)
                if focused != nil { break }
            }
            let action = environment.synthesizedAction()
            if !action.2 { return action.1 }
            return host(application:app,focused:focused,allowNameFallback:false)
        }
        return host(application:app,focused:nil,allowNameFallback:false)
    }
    private func host(application: Node, focused supplied: Node?, allowNameFallback: Bool) -> Int32 {
        if let focused = supplied ?? environment.focused(application), let pid = try? environment.ordinaryPID(focused) {
            if let policy = environment.policy(pid), policy != 2 { return pid }
            let other = environment.application(pid)
            if let actual = try? environment.ordinaryPID(other), let policy = environment.policy(actual), policy != 2 { return actual }
            if let window = environment.focusedWindow(other) ?? environment.mainWindow(other),
               let pid = try? environment.ordinaryPID(window), let policy = environment.policy(pid), policy != 2 { return pid }
        }
        if allowNameFallback, let pid = try? environment.ordinaryPID(application), environment.policy(pid) != nil,
           let host = environment.nameHostPID(pid) { return host }
        return environment.frontmostPID() ?? 0
    }
    static func hostName(_ localizedName: String) -> String? {
        guard localizedName.contains("("), localizedName.contains(")"),
              let last = localizedName.lastIndex(where:{$0 != ")"}),
              let open = localizedName[..<last].lastIndex(of:"(") else { return nil }
        return String(localizedName[localizedName.index(after:open)..<localizedName.index(after:last)])
    }
}

/// Create/post the first notice before constructing the second.
enum ControllerGlobalFocusRepair {
    static func perform<Event>(pid: Int32, make: (UInt16) throws -> Event,
        timestampAndPost: (Event, Int32) -> Void) throws {
        for subtype: UInt16 in [0x4000,0x8000] { timestampAndPost(try make(subtype),pid) }
    }
}
