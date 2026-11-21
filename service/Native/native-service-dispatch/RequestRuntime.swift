import Foundation
import CoreFoundation

/// Per-request deadlines and per-app serialization apply across connections,
/// unlike the JS client's queue, which only protects its own transport.
enum RequestRuntime {
    fileprivate final class Scope: NSObject, @unchecked Sendable {
        let deadline: TimeInterval
        let cancelled: () -> Bool
        let checkpoint: () throws -> Void
        let peerPID: Int32?
        let senderContext: SenderRequestContext?
        init(_ deadline: TimeInterval, cancelled: @escaping () -> Bool, checkpoint: @escaping () throws -> Void = {}, peerPID: Int32? = nil,
             senderContext: SenderRequestContext? = nil) {
            self.deadline = deadline; self.cancelled = cancelled; self.checkpoint = checkpoint; self.peerPID = peerPID
            self.senderContext = senderContext
        }
    }
    private final class Gate {
        let condition = NSCondition()
        var owner: ObjectIdentifier?
        var depth = 0
        var waiting: [UUID] = []
        // Protected by gatesLock, including callers waiting to enter.
        var users = 0

        func enter() throws {
            condition.lock(); defer { condition.unlock() }
            let thread = ObjectIdentifier(Thread.current)
            if owner == thread { depth += 1; return }
            let token = UUID()
            waiting.append(token)
            do {
                while owner != nil || waiting.first != token {
                    try RequestRuntime.check()
                    _ = condition.wait(until: Date(timeIntervalSinceNow: 0.01))
                }
                try RequestRuntime.check()
                waiting.removeFirst()
                owner = thread; depth = 1
            } catch {
                waiting.removeAll { $0 == token }
                condition.broadcast()
                throw error
            }
        }

        func leave() {
            condition.lock(); defer { condition.unlock() }
            precondition(owner == ObjectIdentifier(Thread.current) && depth > 0)
            depth -= 1
            if depth == 0 { owner = nil; condition.broadcast() }
        }
    }
    private static let contextKey = "acua.requestScope"
    @TaskLocal private static var asyncScope: Scope?
    private static var currentScope: Scope? {
        (Thread.current.threadDictionary[contextKey] as? Scope) ?? asyncScope
    }
    struct AsyncScope: Sendable { fileprivate let value: Scope? }
    static func asynchronousScope() -> AsyncScope { .init(value:currentScope) }
    static func withAsyncScope<T>(_ scope:AsyncScope,operation:() async throws -> T) async rethrows -> T {
        try await $asyncScope.withValue(scope.value) {try await operation()}
    }
    private static let gatesLock = NSLock()
    private static var gates: [String: Gate] = [:]

    static func withRequest<T>(_ params: JSON, cancelled: @escaping () -> Bool = { false }, peerPID: Int32? = nil,
                               senderContext: SenderRequestContext? = nil, body: () throws -> T) throws -> T {
        let seconds: Double
        if let raw = params["deadlineUnixMilliseconds"], !(raw is NSNull) {
            guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                throw ServiceError(.couldNotGetRequestData, "Invalid request deadline")
            }
            seconds = number.doubleValue / 1000 - Date().timeIntervalSince1970
        } else { seconds = 120 }
        let previous = Thread.current.threadDictionary[contextKey]
        let parent = (previous as? Scope) ?? asyncScope
        let deadline = min(ProcessInfo.processInfo.systemUptime + min(seconds, 86400), parent?.deadline ?? .infinity)
        let effectivePID = peerPID ?? senderContext?.senderPID ?? parent?.peerPID
        let identity = senderContext ?? (effectivePID == parent?.peerPID ? parent?.senderContext : nil)
        // An internal caller cannot lend one peer's identity to a different peer.
        let matchedIdentity = identity?.senderPID == effectivePID ? identity : nil
        Thread.current.threadDictionary[contextKey] = Scope(deadline, cancelled: { cancelled() || (parent?.cancelled() ?? false) }, checkpoint: { try parent?.checkpoint() }, peerPID: effectivePID, senderContext: matchedIdentity)
        defer { Thread.current.threadDictionary[contextKey] = previous }
        try check()
        return try body()
    }

    static func check() throws {
        guard let scope = currentScope else { return }
        if scope.cancelled() { throw ServiceError(.unknownError, "Request cancelled") }
        if ProcessInfo.processInfo.systemUptime >= scope.deadline {
            throw ServiceError(.unknownError, "Request deadline exceeded")
        }
        try scope.checkpoint()
    }

    static func withCheckpoint<T>(_ checkpoint: @escaping () throws -> Void, body: () throws -> T) throws -> T {
        let previous = Thread.current.threadDictionary[contextKey]
        let parent = (previous as? Scope) ?? asyncScope
        Thread.current.threadDictionary[contextKey] = Scope(parent?.deadline ?? (ProcessInfo.processInfo.systemUptime + 120),
            cancelled: { parent?.cancelled() ?? false }, checkpoint: { try parent?.checkpoint(); try checkpoint() }, peerPID: parent?.peerPID,
            senderContext: parent?.senderContext)
        defer { Thread.current.threadDictionary[contextKey] = previous }
        try check()
        let result = try body()
        try check()
        return result
    }
    static var peerPID: Int32? { currentScope?.peerPID }
    static var senderContext: SenderRequestContext? { currentScope?.senderContext }

    /// Synchronous AX work may cross to the main thread while retaining the
    /// caller's deadline, cancellation and automation-session checkpoint.
    static func onMainThread<T>(_ body: () throws -> T) throws -> T {
        if Thread.isMainThread { return try body() }
        let scope = currentScope
        return try DispatchQueue.main.sync {
            let previous = Thread.current.threadDictionary[contextKey]
            Thread.current.threadDictionary[contextKey] = scope
            defer { Thread.current.threadDictionary[contextKey] = previous }
            try check()
            let value = try body()
            try check()
            return value
        }
    }

    struct WorkerScope: Sendable {
        fileprivate let deadline: TimeInterval
        fileprivate let peerPID: Int32?
        fileprivate let senderContext: SenderRequestContext?
    }
    /// A capture outlives the Start response, so retain its deadline/peer rather
    /// than retaining the initiating connection's cancellation closure.
    static func workerScope() -> WorkerScope {
        let parent = currentScope
        return WorkerScope(deadline: parent?.deadline ?? (ProcessInfo.processInfo.systemUptime + 120), peerPID: parent?.peerPID,
                           senderContext: parent?.senderContext)
    }
    static func withWorkerScope<T>(_ worker: WorkerScope, cancelled: @escaping () -> Bool, body: () throws -> T) throws -> T {
        let previous = Thread.current.threadDictionary[contextKey]
        Thread.current.threadDictionary[contextKey] = Scope(worker.deadline, cancelled: cancelled, peerPID: worker.peerPID,
                                                         senderContext: worker.senderContext)
        defer { Thread.current.threadDictionary[contextKey] = previous }
        try check()
        let result = try body()
        try check()
        return result
    }

    static func wait(_ seconds: Double) throws {
        guard seconds.isFinite, seconds >= 0 else { throw ServiceError(.unhandledEvent, "Invalid wait duration") }
        let until = ProcessInfo.processInfo.systemUptime + seconds
        repeat {
            try check()
            let remaining = until - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return }
            Thread.sleep(forTimeInterval: min(remaining, 0.01))
        } while true
    }

    static func wait(for semaphore: DispatchSemaphore, maximumSeconds: Double) throws {
        guard maximumSeconds.isFinite, maximumSeconds >= 0 else {
            throw ServiceError(.unknownError, "Invalid operation timeout")
        }
        let limit = ProcessInfo.processInfo.systemUptime + maximumSeconds
        while true {
            try check()
            if semaphore.wait(timeout: .now() + 0.01) == .success { try check(); return }
            if ProcessInfo.processInfo.systemUptime >= limit {
                throw ServiceError(.unknownError, "Operation timed out")
            }
        }
    }

    static func serialized<T>(app: String, body: () throws -> T) throws -> T {
        gatesLock.lock()
        let gate = gates[app] ?? Gate()
        gate.users += 1
        gates[app] = gate
        gatesLock.unlock()
        defer {
            gatesLock.lock()
            gate.users -= 1
            if gate.users == 0 { gates.removeValue(forKey: app) }
            gatesLock.unlock()
        }
        try gate.enter()
        defer { gate.leave() }
        try check()
        return try body()
    }

    static func queuedRequestCount(app: String) -> Int {
        gatesLock.lock()
        let gate = gates[app]
        gatesLock.unlock()
        guard let gate else { return 0 }
        gate.condition.lock(); defer { gate.condition.unlock() }
        return gate.waiting.count
    }

    static var activeAppCount: Int {
        gatesLock.lock(); defer { gatesLock.unlock() }
        return gates.count
    }
}
