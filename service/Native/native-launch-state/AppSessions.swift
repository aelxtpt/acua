import Foundation

struct IPCApp: Codable, Equatable, Sendable {
    let pid: Int32
    let bundleIdentifier: String
    let appPath: String?
    var json: JSON {
        var value: JSON = ["pid": pid, "bundleIdentifier": bundleIdentifier]
        if let appPath { value["appPath"] = appPath }
        return value
    }
}

struct IPCAppState: Codable, Sendable {
    let active: Bool
    let currentApp: IPCApp?
    var json: JSON {
        var value: JSON = ["active": active]
        if let currentApp { value["currentApp"] = currentApp.json }
        return value
    }
}

/// Session state is independent of OS application activation. In particular,
/// deactivation releases automation state without hiding or terminating an app.
final class AppSessions {
    static let shared = AppSessions()
    struct Token { let bundle: String; let process: String; let epoch: UUID }
    private struct Entry {
        let app: IPCApp
        let process: String
        var active: Bool
        var epoch = UUID()
        var needsSettling = false
    }
    private enum Intervention { case stopped; case interrupted(deadline: Double) }
    private var entries: [String: Entry] = [:]
    private var entryOrder: [String] = []
    private var interventions: [String: Intervention] = [:]
    private let lock = NSLock()
    private let now: () -> Double
    init(now: @escaping () -> Double = { Date().timeIntervalSince1970 }) { self.now = now }

    private func interventionError(_ bundle: String, allowRequery: Bool) throws {
        switch interventions[bundle] {
        case .stopped: throw ServiceError(.userStoppedSession, "Session was stopped by the user")
        case .interrupted(let deadline) where !allowRequery:
            let seconds = max(0, ceil(deadline - now()))
            throw ServiceError(.userIntervened, "User intervened; read app state again after the debounce interval (\(seconds) seconds remaining)")
        default: break
        }
    }
    func validateStart(_ bundle: String, allowRequery: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        try interventionError(bundle, allowRequery: allowRequery)
    }

    func prepare(app: IPCApp, process: String, create: Bool, requery: Bool = false) throws -> Token {
        lock.lock(); defer { lock.unlock() }
        let bundle = app.bundleIdentifier
        if case .stopped = interventions[bundle] { throw ServiceError(.userStoppedSession, "Session was stopped by the user") }
        if let previous = entries[bundle], previous.process != process {
            entries.removeValue(forKey: bundle)
            entryOrder.removeAll { $0 == bundle }
            if case .interrupted = interventions[bundle] { interventions.removeValue(forKey: bundle) }
        }
        try interventionError(bundle, allowRequery: requery)
        if entries[bundle] == nil {
            guard create else { throw ServiceError(.noActiveSession, "No active automation session; read app state or start the app first") }
            entries[bundle] = Entry(app: app, process: process, active: true)
            entryOrder.append(bundle)
        }
        let entry = entries[bundle]!
        return Token(bundle: bundle, process: process, epoch: entry.epoch)
    }

    func check(_ token: Token, requery: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        try interventionError(token.bundle, allowRequery: requery)
        guard let entry = entries[token.bundle], entry.process == token.process, entry.epoch == token.epoch else {
            if case .interrupted = interventions[token.bundle] { throw ServiceError(.userIntervened, "User intervened during the request; read app state again") }
            throw ServiceError(.noActiveSession, "Automation session changed during the request")
        }
    }

    func activeToken(for bundle: String, process: String) -> Token? {
        lock.withLock {
            guard interventions[bundle] == nil, let entry = entries[bundle], entry.active, entry.process == process else { return nil }
            return Token(bundle: bundle, process: process, epoch: entry.epoch)
        }
    }

    @discardableResult
    func exchangeSettling(_ pending: Bool, for token: Token, requery: Bool = false) throws -> Bool {
        try lock.withLock {
            try interventionError(token.bundle, allowRequery: requery)
            guard var entry = entries[token.bundle], entry.process == token.process, entry.epoch == token.epoch else {
                if case .interrupted = interventions[token.bundle] { throw ServiceError(.userIntervened, "User intervened during the request; read app state again") }
                throw ServiceError(.noActiveSession, "Automation session changed during the request")
            }
            let previous = entry.needsSettling
            entry.needsSettling = pending
            entries[token.bundle] = entry
            return previous
        }
    }

    func didRequery(_ token: Token) throws {
        lock.lock(); defer { lock.unlock() }
        try interventionError(token.bundle, allowRequery: true)
        guard let entry = entries[token.bundle], entry.process == token.process, entry.epoch == token.epoch else {
            if case .interrupted = interventions[token.bundle] { throw ServiceError(.userIntervened, "User intervened while app state was being read") }
            throw ServiceError(.noActiveSession, "Automation session changed while app state was being read")
        }
        if case .interrupted(let deadline) = interventions[token.bundle], now() >= deadline { interventions.removeValue(forKey: token.bundle) }
    }

    func activate(_ token: Token) throws -> IPCAppState {
        lock.lock(); defer { lock.unlock() }
        try interventionError(token.bundle, allowRequery: false)
        guard var entry = entries[token.bundle], entry.process == token.process, entry.epoch == token.epoch else { throw ServiceError(.noActiveSession, "Automation session changed") }
        entry.active = true; entries[token.bundle] = entry
        return IPCAppState(active: true, currentApp: entry.app)
    }

    func stop(_ bundle: String) -> IPCAppState {
        lock.lock(); defer { lock.unlock() }
        interventions[bundle] = .stopped
        if var entry = entries[bundle] {
            entry.active = false; entry.epoch = UUID(); entry.needsSettling = false; entries[bundle] = entry
        }
        return IPCAppState(active: false, currentApp: entries[bundle]?.app)
    }

    func deactivate(_ token: Token) throws -> IPCAppState {
        lock.lock(); defer { lock.unlock() }
        if case .stopped = interventions[token.bundle] { throw ServiceError(.userStoppedSession, "Session was stopped by the user") }
        guard let entry = entries[token.bundle], entry.process == token.process, entry.epoch == token.epoch else { throw ServiceError(.noActiveSession, "No active automation session") }
        entries.removeValue(forKey: token.bundle); interventions.removeValue(forKey: token.bundle)
        entryOrder.removeAll { $0 == token.bundle }
        return IPCAppState(active: false, currentApp: entry.app)
    }

    func interrupt(_ bundle: String, debounce: Double = 5) {
        lock.lock(); defer { lock.unlock() }
        _ = interruptLocked(bundle, debounce: debounce)
    }

    /// Resolve against the live session's PID under the same lock as invalidation.
    /// Input in an unrelated app must not cancel all automation sessions.
    func interrupt(pid: Int32, process: String? = nil, debounce: Double = 5) -> [String] {
        lock.lock(); defer { lock.unlock() }
        let bundles = entries.filter { $0.value.app.pid == pid && (process == nil || $0.value.process == process) }.map(\.key)
        return bundles.filter { interruptLocked($0, debounce: debounce) }
    }

    private func interruptLocked(_ bundle: String, debounce: Double) -> Bool {
        guard var entry = entries[bundle], entry.active else { return false }
        if case .stopped = interventions[bundle] { return false }
        entry.epoch = UUID(); entry.needsSettling = false; entries[bundle] = entry
        interventions[bundle] = .interrupted(deadline: now() + max(0, debounce.isFinite ? debounce : 5))
        return true
    }

    /// Host user controls may explicitly clear a stop. AppStart and state
    /// queries deliberately do not silently override a user stop.
    func clearStoppedByUser(_ bundle: String) {
        lock.lock(); defer { lock.unlock() }
        if case .stopped = interventions[bundle] { interventions.removeValue(forKey: bundle) }
    }

    func activeApplications() -> [(app: IPCApp, process: String)] {
        lock.lock(); defer { lock.unlock() }
        return entryOrder.compactMap { bundle in
            guard let entry = entries[bundle], entry.active else { return nil }
            return (entry.app, entry.process)
        }
    }
}
