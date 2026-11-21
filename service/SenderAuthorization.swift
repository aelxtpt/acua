import AppKit
import Foundation
import Darwin
import Security

struct PeerAuditCredentials {
    let pid: Int32
    let uid: uid_t
    let auditToken: Data
    static func read(fd: Int32) -> PeerAuditCredentials? {
        var token = audit_token_t(), length = socklen_t(MemoryLayout<audit_token_t>.size)
        // The kernel audit token from SOL_LOCAL/LOCAL_PEERTOKEN, exactly 32 bytes.
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == 32 else { return nil }
        var pid: Int32 = 0, pidLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pidLength) == 0,
              pidLength == MemoryLayout<Int32>.size, pid > 0,
              UInt32(bitPattern: pid) == token.val.5 else { return nil }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        let data = withUnsafeBytes(of: &token) { Data($0) }
        return PeerAuditCredentials(pid: pid, uid: uid, auditToken: data)
    }
}

enum SenderProcessResponsibility {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t
    private static let lookup: Lookup? = {
        guard let process = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(process, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    // Responsibility is resolved for the sender's parent, not the sender.
    static func responsiblePID(for senderPID: pid_t) -> pid_t? {
        guard let lookup, let parent = parentPID(for: senderPID) else { return nil }
        let responsible = lookup(parent)
        return responsible > 0 ? responsible : nil
    }

    static func parentPID(for pid: pid_t) -> pid_t? {
        guard pid > 0 else { return nil }
        var query = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        guard sysctl(&query, UInt32(query.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, info.kp_eproc.e_ppid > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    // The visited set starts with the peer itself and the walk stops after eight parents.
    static func ancestors(of pid: pid_t, parent: (pid_t) -> pid_t? = parentPID) -> [pid_t] {
        var chain = [pid_t]()
        var visited: Set<pid_t> = [pid]
        var current = pid
        for _ in 0..<8 {
            guard let next = parent(current), next > 0, visited.insert(next).inserted else { break }
            chain.append(next)
            current = next
        }
        return chain
    }
}

enum SigningTeam {
    static func information(_ code: SecCode) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else { return nil }
        return information
    }
    private static func identifier(_ code: SecCode) -> String? {
        information(code)?[kSecCodeInfoTeamIdentifier as String] as? String
    }
    /// The service's own team, read from its own code signature.
    static func own() -> String? {
        AcuaOwnIdentity.signingTeam()
    }
    static func peer(auditToken: Data) -> String? {
        guard auditToken.count == 32 else { return nil }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        return identifier(code)
    }
    static func process(_ pid: pid_t) -> String? {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return nil }
        return identifier(code)
    }
}

extension SenderProcessIdentity {
    static func resolve(_ pid: pid_t) -> Self {
        let app = NSRunningApplication(processIdentifier: pid)
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        var code: SecCode?
        let information: [String: Any]?
        if SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code {
            information = SigningTeam.information(code)
        } else {
            information = nil
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let executable: String?
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
            executable = URL(fileURLWithPath: path).lastPathComponent
        } else {
            executable = app?.executableURL?.lastPathComponent ?? app?.localizedName
        }

        return Self(team: information?[kSecCodeInfoTeamIdentifier as String] as? String,
                    signingID: information?[kSecCodeInfoIdentifier as String] as? String,
                    bundleID: app?.bundleIdentifier, executable: executable)
    }

}

extension SenderRequestContext {
    static func resolveNative(_ senderPID: Int32) -> Self? {
        var context = Resolver(ancestorPIDs: { SenderProcessResponsibility.ancestors(of: $0) },
                 identity: SenderProcessIdentity.resolve,
                 responsiblePID: SenderProcessResponsibility.responsiblePID).resolve(senderPID)
        context?.clientMetadata = .socket
        return context
    }
}

/// The sender's context is trusted only when its immediate parent is signed by
/// the service's own team. A trusted process farther up the chain does not
/// make up for an untrusted parent.
enum SenderContextAuthorization {
    static func allows(_ ancestors: [SenderProcessIdentity], ownTeam: String) -> Bool {
        guard let parent = ancestors.first else { return false }
        return parent.team == ownTeam
    }
}

/// Default admission is same-local-user. The signed-client policies below
/// additionally require the peer to be signed by the service's own team; a
/// missing own TeamIdentifier rejects every peer. Only successful signature
/// matches are cached, keyed by the full kernel audit token (which includes
/// the PID version), never by a caller-supplied PID.
final class SenderAuthorization {
    static let shared = SenderAuthorization()
    static let developmentVariable = "ACUA_ALLOW_UNSIGNED_LOCAL_CLIENTS"
    private let lock = NSLock()
    private var acceptedTeams: [Data: String] = [:]
    private let ownTeam: () -> String?
    private let peerTeam: (Data) -> String?
    private let ancestors: (pid_t) -> [SenderProcessIdentity]
    private let processTeam: (pid_t) -> String?
    init(ownTeam: @escaping () -> String? = SigningTeam.own,
         peerTeam: @escaping (Data) -> String? = SigningTeam.peer,
         ancestors: @escaping (pid_t) -> [SenderProcessIdentity] = {
             SenderProcessResponsibility.ancestors(of: $0).map(SenderProcessIdentity.resolve)
         }, processTeam: @escaping (pid_t) -> String? = SigningTeam.process) {
        self.ownTeam = ownTeam
        self.peerTeam = peerTeam
        self.ancestors = ancestors
        self.processTeam = processTeam
    }
    /// Aex Computer Use admits any process of the same local user, whatever
    /// launched it (Claude Code, Codex, Cursor, Terminal, ...). The stricter
    /// signature-based rule is `allowsSignedClient`.
    func allows(_ credentials: PeerAuditCredentials, development: Bool = false, serviceUID: uid_t = geteuid()) -> Bool {
        guard credentials.pid > 0, credentials.auditToken.count == 32 else { return false }
        return credentials.uid == serviceUID
    }

    /// Signed-client admission: the peer and its immediate parent must both be
    /// signed by the service's own team.
    func allowsSignedClient(_ credentials: PeerAuditCredentials) -> Bool {
        guard credentials.pid > 0, credentials.auditToken.count == 32 else { return false }
        guard let own = ownTeam() else { return false }
        lock.lock(); let cached = acceptedTeams[credentials.auditToken]; lock.unlock()
        if cached != own {
            guard let team = peerTeam(credentials.auditToken), team == own else { return false }
            lock.withLock { acceptedTeams[credentials.auditToken] = team }
        }
        return SenderContextAuthorization.allows(ancestors(credentials.pid), ownTeam: own)
    }
    var cachedCount: Int { lock.lock(); defer { lock.unlock() }; return acceptedTeams.count }

    /// Same-local-user admission for the Apple Event/Mach-XPC bootstrap.
    func authorizeAppleEvent(_ sender: AppleEventAuthorization.Sender, development: Bool = false,
                             serviceUID: uid_t = geteuid(),
                             isDesignatedHost: @escaping (pid_t) -> Bool = SenderAuthorization.isDesignatedHost,
                             resolveContext: @escaping (pid_t) -> SenderRequestContext? = SenderRequestContext.resolveNative) throws -> SenderRequestContext {
        do {
            guard let pid = sender.pid else { throw AppleEventAuthorization.Failure.missingSenderPID }
            guard let data = sender.auditData, data.count == MemoryLayout<audit_token_t>.size else {
                throw AppleEventAuthorization.Failure.notAuthenticated
            }
            let token = data.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
            guard pid > 0, token.val.5 == UInt32(bitPattern: pid), token.val.1 == serviceUID else {
                throw AppleEventAuthorization.Failure.notAuthenticated
            }
            return (resolveContext(pid) ?? .init(senderPID: pid, responsibleIdentity: nil, ancestorIdentities: []))
                .withAppleEventMetadata(clientType: sender.clientType, version: sender.version)
        }
    }

    /// Signed-client admission for Apple Events (see `AppleEventAuthorization`),
    /// using the service's own team for both the sender and its parent.
    func authorizeAppleEventSignedClient(_ sender: AppleEventAuthorization.Sender,
                             isDesignatedHost: @escaping (pid_t) -> Bool = SenderAuthorization.isDesignatedHost,
                             resolveContext: @escaping (pid_t) -> SenderRequestContext? = SenderRequestContext.resolveNative) throws -> SenderRequestContext {
        let policy = AppleEventAuthorization(providers: .init(ownTeam: ownTeam, auditMatches: { [self] data, team in
            lock.lock(); let cached = acceptedTeams[data]; lock.unlock()
            if let cached { return cached == team }
            guard let observed = peerTeam(data), observed == team else { return false }
            lock.withLock { acceptedTeams[data] = observed }
            return true
        }, processMatches: { [self] pid, team in processTeam(pid) == team },
            isDesignatedHost: isDesignatedHost, resolveContext: resolveContext,
            contextAllowed: { [self] context in
                ownTeam().map { SenderContextAuthorization.allows(context.ancestorIdentities, ownTeam: $0) } ?? false
            }))
        return try policy.authorize(sender)
    }

    /// A designated host is one of ACUA's own applications.
    private static func isDesignatedHost(_ pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        let identifier = app.bundleIdentifier ?? app.bundleURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        return identifier.map(AcuaOwnIdentity.isOwnBundleIdentifier) ?? false
    }
}

final class ServiceClientLifetime: @unchecked Sendable {
    /// `managed` when the service was started by one of ACUA's own apps: the
    /// service then lives as long as that parent. Otherwise `standalone`: it
    /// lives as long as its connected clients.
    enum Mode: Equatable {
        case managed(pid_t)
        case standalone

        static func detect(parent: pid_t? = SenderProcessResponsibility.parentPID(for: getpid()),
                           identity: (pid_t) -> SenderProcessIdentity = SenderProcessIdentity.resolve) -> Self {
            guard let parent, identity(parent).hasOwnBundleIdentifier else {
                return .standalone
            }
            return .managed(parent)
        }
    }

    private let lock = NSLock()
    private let mode: Mode
    private let onExit: @MainActor () -> Void
    private var sources = [pid_t: DispatchSourceProcess]()
    private var stopped = false

    init(mode: Mode, onExit: @escaping @MainActor () -> Void) {
        self.mode = mode
        self.onExit = onExit
    }

    func start() {
        if case .managed(let owner) = mode { watch(owner) }
    }

    func admit(_ peer: pid_t) {
        if mode == .standalone { watch(peer) }
    }

    func stop() {
        lock.withLock {
            stopped = true
            sources.values.forEach { $0.cancel() }
            sources.removeAll()
        }
    }

    private func watch(_ pid: pid_t) {
        guard pid > 0 else { return }
        lock.withLock {
            guard !stopped, sources[pid] == nil else { return }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.processExited(pid) }
            }
            sources[pid] = source
            source.activate()
        }
    }

    @MainActor private func processExited(_ pid: pid_t) {
        let shouldExit = lock.withLock {
            guard let source = sources.removeValue(forKey: pid) else { return false }
            source.cancel()
            guard sources.isEmpty else { return false }
            stopped = true
            return true
        }
        if shouldExit { onExit() }
    }
}

@MainActor
final class ServiceIdleTimer {
    private let idlePeriod: Duration
    private let keepAlive: () -> Bool
    private let onIdle: () -> Void
    private var task: Task<Void, Never>?
    private var stopped = false

    init(idlePeriod: Duration = .seconds(300), keepAlive: @escaping () -> Bool, onIdle: @escaping () -> Void) {
        self.idlePeriod = idlePeriod
        self.keepAlive = keepAlive
        self.onIdle = onIdle
    }

    func reset() {
        guard !stopped else { return }
        task?.cancel()
        task = Task { [weak self, idlePeriod] in
            do { try await Task.sleep(for: idlePeriod, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            task = nil
            if keepAlive() {
                reset()
            } else {
                stopped = true
                onIdle()
            }
        }
    }

    func stop() {
        stopped = true
        task?.cancel()
        task = nil
    }
}
