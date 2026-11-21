import AppKit
import Combine
import Darwin
import Foundation

@objc(OwnedPIPConnectionBootstrap) private protocol BootstrapProtocol {
    func endpoint(reply: @escaping (NSXPCListenerEndpoint, Int32) -> Void)
    func snapshot(reply: @escaping (Data) -> Void)
    func retry(reply: @escaping () -> Void)
    func shutdown(reply: @escaping () -> Void)
}

@MainActor private final class SnapshotBuilder {
    private var identities = [UUID: Int]()
    func value(_ d: RemoteHostedPIPContentConnectionDiagnostics) -> [String: Any] {
        let events: [[String: Any]] = d.events.map { event in
            if identities[event.id] == nil { identities[event.id] = identities.count }
            let details = event.details?.replacingOccurrences(of: #"Connection lifetime: [^\n]+ seconds"#,
                with: "Connection lifetime: <elapsed> seconds", options: .regularExpression)
            return ["idOrdinal": identities[event.id]!, "message": event.message, "details": details as Any? ?? NSNull(),
                "error": event.error.map { ["domain": $0.domain, "code": $0.code, "message": $0.message] as [String: Any] } ?? NSNull()]
        }
        return ["status": String(describing: d.status), "attemptCount": d.attemptCount,
            "lastAttemptDatePresent": d.lastAttemptDate != nil, "nextRetryDatePresent": d.nextRetryDate != nil,
            "connectedDatePresent": d.connectedDate != nil,
            "hostProcess": d.hostProcess.map { ["processIdentifier": $0.processIdentifier,
                "bundleIdentifier": $0.bundleIdentifier as Any? ?? NSNull(), "displayName": $0.displayName as Any? ?? NSNull()] as [String: Any] } ?? NSNull(),
            "events": events]
    }
}

// Owned protocol receiver for testing the production connection component. The
// actual publisher's other producer handlers/stream implementation are separate.
@MainActor private final class FixtureOwner: NSObject, RemoteHostedPIPConnectionOwner {
    var transport: RemoteHostedPIPConnection!
    var resets = 0, replays = 0, clears = 0
    var lastPeerPID: Int32 = -1
    var effects = [String]()
    func resetRemoteHostedStreams() {
        if let pid = transport.connection?.processIdentifier { lastPeerPID = pid }
        resets += 1; effects.append("reset")
    }
    func enqueueRemoteHostedStreamsAndCursorReplay() { replays += 1; effects.append("enqueueReplay") }
    func clearRemoteHostedPetLocation() { clears += 1; effects.append("clearPet") }
    nonisolated func connect(reply: @escaping RemoteHostedPIPReply) {
        Task { @MainActor [weak self] in self?.transport.didCompleteHandshake() }
        reply(nil)
    }
    nonisolated func setMaxDisplaySize(_ size: Double, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    nonisolated func setVideoMaxPixelDimension(_ dimension: Double, presentationID: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    nonisolated func performAction(presentationID: String, kind: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    nonisolated func didEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    nonisolated func setPetLocation(x: Double, y: Double, available: Bool, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
}

@MainActor private final class Bootstrap: NSObject, BootstrapProtocol {
    let owner: FixtureOwner
    init(_ owner: FixtureOwner) { self.owner = owner }
    nonisolated func endpoint(reply: @escaping (NSXPCListenerEndpoint, Int32) -> Void) {
        Task { @MainActor in reply(self.owner.transport.endpointForHostConnection(), getpid()) }
    }
    nonisolated func snapshot(reply: @escaping (Data) -> Void) {
        Task { @MainActor in
            let d = self.owner.transport.connectionDiagnostics
            let value: [String: Any] = ["status": String(describing: d.status), "attemptCount": d.attemptCount,
                "peerPID": self.owner.transport.connection?.processIdentifier ?? -1, "hostPID": d.hostProcess?.processIdentifier ?? -1,
                "events": d.events.map(\.message), "details": d.events.first?.details ?? "", "resets": self.owner.resets,
                "replays": self.owner.replays, "clears": self.owner.clears, "effects": self.owner.effects, "pid": getpid(),
                "fixtureHostVisibleToWorkspace": NSRunningApplication(processIdentifier: self.owner.lastPeerPID) != nil]
            reply(try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys))
        }
    }
    nonisolated func retry(reply: @escaping () -> Void) {
        Task { @MainActor in self.owner.transport.retryConnection(); reply() }
    }
    nonisolated func shutdown(reply: @escaping () -> Void) {
        reply(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) }
    }
}

private final class BootstrapDelegate: NSObject, NSXPCListenerDelegate {
    let object: Bootstrap
    var connections = [NSXPCConnection]()
    init(_ object: Bootstrap) { self.object = object }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: BootstrapProtocol.self)
        connection.exportedObject = object; connections.append(connection); connection.activate(); return true
    }
}

@main @MainActor private enum Tests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        checks += 1; print("PASS: \(label)")
    }

    static func main() async throws {
        if Bundle.main.bundleIdentifier?.hasSuffix(".child") == true {
            let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try JSONSerialization.data(withJSONObject: ["pid": getpid(), "executable": Bundle.main.executableURL!.path]).write(to: root.appendingPathComponent("child-pid.json"))
            let owner = FixtureOwner(); owner.transport = RemoteHostedPIPConnection(owner: owner)
            let object = Bootstrap(owner), delegate = BootstrapDelegate(object), listener = NSXPCListener.service()
            listener.delegate = delegate
            withExtendedLifetime((owner, object, delegate, listener)) { listener.resume(); dispatchMain() }
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), corpusURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: corpusURL)) as! [String: Any]
        let expected = corpus["snapshots"] as! [[String: Any]]
        let owner = FixtureOwner(); owner.transport = RemoteHostedPIPConnection(owner: owner)
        let transport = owner.transport!, builder = SnapshotBuilder()
        var snapshots = [[String: Any]]()
        func snapshot(_ name: String) { snapshots.append(["name": name, "diagnostics": builder.value(transport.connectionDiagnostics)]) }
        snapshot("initial")
        transport.start(); snapshot("start-without-connection")
        transport.retryConnection(); snapshot("retry-without-connection")
        for index in 1...53 {
            _ = transport.endpointForHostConnection()
            if [1, 2, 50, 51, 53].contains(index) { snapshot("endpoint-\(index)") }
        }
        let listener = NSXPCListener.anonymous(); listener.activate(); defer { listener.invalidate() }
        let a = NSXPCConnection(listenerEndpoint: listener.endpoint), b = NSXPCConnection(listenerEndpoint: listener.endpoint)
        transport.adopt(a); snapshot("adopt-A")
        let connectedDate = transport.connectionDiagnostics.connectedDate
        var duplicateEmissions = 0
        let observation = transport.objectWillChange.sink { duplicateEmissions += 1 }
        transport.adopt(a); snapshot("adopt-A-again")
        check(duplicateEmissions == 0, "duplicate adoption does not emit an observable diagnostic change")
        observation.cancel()
        transport.didCompleteHandshake(); snapshot("handshake-A")
        transport.didInterrupt(a); snapshot("interrupt-A")
        transport.start(); snapshot("start-with-A")
        _ = transport.endpointForHostConnection(); snapshot("endpoint-with-A")
        check(transport.connectionDiagnostics.connectedDate == connectedDate && transport.connection === a,
            "endpoint request preserves the current connection and its connected date")
        transport.start(); snapshot("restart-with-A")
        transport.adopt(b); snapshot("replace-with-B")
        transport.didInterrupt(a); snapshot("stale-interrupt-A")
        transport.didInvalidate(a); snapshot("stale-invalidate-A")
        transport.didInvalidate(b); snapshot("invalidate-B")
        transport.didInvalidate(b); snapshot("invalidate-B-again")
        transport.didCompleteHandshake(); snapshot("handshake-without-connection")
        let c = NSXPCConnection(listenerEndpoint: listener.endpoint)
        transport.adopt(c); snapshot("adopt-C")
        transport.didCompleteHandshake(); snapshot("handshake-C")
        transport.didInterrupt(c); snapshot("interrupt-C")
        transport.retryConnection(); snapshot("retry-with-C")
        transport.didInvalidate(c); snapshot("invalidate-C-after-retry")
        a.invalidate(); b.invalidate(); c.invalidate()
        check(expected.count == snapshots.count, "lifecycle corpus has the same snapshot count")
        for (reference, actual) in zip(expected, snapshots) {
            check(NSDictionary(dictionary: reference).isEqual(to: actual), "lifecycle state matches \(actual["name"]!)")
        }
        check(owner.resets == 5 && owner.replays == 3 && owner.clears == 2,
            "duplicate and stale callbacks do not repeat stream resets, replays or pet cleanup")
        check(owner.effects == ["reset", "enqueueReplay", "reset", "enqueueReplay", "clearPet", "reset", "reset", "enqueueReplay", "clearPet", "reset"],
            "adoption and invalidation effects keep their order")
        let events = transport.connectionDiagnostics.events
        check(events.count == 50 && Set(events.map(\.id)).count == 50
            && zip(events, events.dropFirst()).allSatisfy { $0.date >= $1.date },
            "bounded diagnostic history retains unique event identities and reverse chronological dates")
        check(RemoteHostedPIPContentHostProcess(processIdentifier: 7, bundleIdentifier: "bundle", displayName: "Name").connectionLabel == "bundle"
            && RemoteHostedPIPContentHostProcess(processIdentifier: 7, bundleIdentifier: "bundle", displayName: "Name").diagnosticLabel == "Name, bundle, PID 7",
            "connection and diagnostic host labels keep their distinct priorities")
        check(RemoteHostedPIPContentHostProcess(processIdentifier: -9, bundleIdentifier: nil, displayName: "").connectionLabel == ""
            && RemoteHostedPIPContentHostProcess(processIdentifier: -9, bundleIdentifier: nil, displayName: nil).diagnosticLabel == "PID -9",
            "empty host names are retained and absent names use the signed PID")
        let local = FixtureOwner(); local.transport = RemoteHostedPIPConnection(owner: local)
        var replies = 0; local.connect { error in check(error == nil, "connect acknowledgement has no error"); replies += 1 }
        check(replies == 1 && local.transport.connectionDiagnostics.events.isEmpty,
            "connect acknowledgement precedes its queued MainActor handshake")
        for _ in 0..<100 where local.transport.connectionDiagnostics.events.isEmpty { await Task.yield() }
        check(local.transport.connectionDiagnostics.events.first?.message == "Host handshake completed", "queued handshake runs even before admission")
        weak var released: RemoteHostedPIPConnection?
        autoreleasepool {
            let temporary = FixtureOwner(); temporary.transport = RemoteHostedPIPConnection(owner: temporary)
            released = temporary.transport
        }
        check(released == nil, "listener delegate and callbacks do not retain an owner or connection component cycle")
        let orphan: RemoteHostedPIPConnection = autoreleasepool {
            let temporary = FixtureOwner()
            return RemoteHostedPIPConnection(owner: temporary)
        }
        let orphanClient = NSXPCConnection(listenerEndpoint: orphan.endpointForHostConnection())
        orphanClient.remoteObjectInterface = RemoteHostedPIPXPC.producerInterface(); orphanClient.activate()
        let rejected: Bool = await withCheckedContinuation { continuation in
            let proxy = orphanClient.remoteObjectProxyWithErrorHandler { _ in continuation.resume(returning: true) } as! RemoteHostedPIPContentProducerXPCProtocol
            proxy.connect { _ in continuation.resume(returning: false) }
        }
        orphanClient.invalidate()
        check(rejected && orphan.connection == nil, "listener cannot accept a connection after its producer owner has been released")
        await runNative(directory)
        try JSONSerialization.data(withJSONObject: snapshots, options: .sortedKeys).write(to: directory.appendingPathComponent("lifecycle-snapshots.json"))
    }

    static func runNative(_ directory: URL) async {
        let broker = NSXPCConnection(serviceName: Bundle.main.bundleIdentifier! + ".child")
        broker.remoteObjectInterface = NSXPCInterface(with: BootstrapProtocol.self); broker.activate()
        var bootstrapError: Error?
        let bootstrap = broker.remoteObjectProxyWithErrorHandler { bootstrapError = $0 } as! BootstrapProtocol
        defer { bootstrap.shutdown {}; broker.invalidate() }
        let (endpoint, pid): (NSXPCListenerEndpoint, Int32) = await withCheckedContinuation { continuation in
            bootstrap.endpoint { continuation.resume(returning: ($0, $1)) }
        }
        check(bootstrapError == nil && pid > 0 && pid != getpid(), "native listener endpoint comes from a distinct owned process")
        func state() async -> [String: Any] {
            let data: Data = await withCheckedContinuation { continuation in bootstrap.snapshot { continuation.resume(returning: $0) } }
            return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        func wait(_ label: String, _ predicate: ([String: Any]) -> Bool) async -> [String: Any] {
            for _ in 0..<200 {
                let value = await state()
                if predicate(value) { check(true, label); return value }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            check(false, label); return [:]
        }
        func open() -> NSXPCConnection {
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = RemoteHostedPIPXPC.producerInterface()
            connection.exportedInterface = RemoteHostedPIPXPC.hostInterface(); connection.activate(); return connection
        }
        func handshake(_ connection: NSXPCConnection) async {
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in fputs("Native handshake error: \(error)\n", stderr); exit(1) } as! RemoteHostedPIPContentProducerXPCProtocol
            let error: NSError? = await withCheckedContinuation { continuation in proxy.connect { continuation.resume(returning: $0) } }
            check(error == nil, "native producer acknowledges connect")
        }
        let a = open(); defer { a.invalidate() }
        // NSXPCConnection opens lazily on its first message.
        await handshake(a)
        let first = await wait("production listener adopts the native peer and records handshake") {
            $0["status"] as? String == "connected" && ($0["events"] as? [String])?.contains("Host handshake completed") == true
        }
        check(first["peerPID"] as? Int32 == getpid() && first["hostPID"] as? Int32 == getpid() && a.processIdentifier == pid,
            "native admission and diagnostics use actual kernel peer process identifiers")
        check(first["resets"] as? Int == 1 && first["replays"] as? Int == 1, "native adoption runs reset and replay hooks once")
        let b = open(); defer { b.invalidate() }; await handshake(b)
        let second = await wait("native replacement survives invalidation of the old peer") {
            $0["status"] as? String == "connected" && $0["replays"] as? Int == 2
        }
        a.invalidate()
        try? await Task.sleep(nanoseconds: 30_000_000)
        let afterStale = await state()
        check(afterStale["status"] as? String == "connected" && afterStale["clears"] as? Int == 0,
            "late invalidation from replaced native connection cannot clear the current peer")
        await withCheckedContinuation { continuation in bootstrap.retry { continuation.resume() } }
        let retried = await wait("manual retry invalidates the active native connection") { $0["status"] as? String == "waitingForHost" && $0["clears"] as? Int == 1 }
        check((retried["details"] as? String)?.contains("Observed cause: Publisher requested invalidation for a manual retry.") == true
            && retried["peerPID"] as? Int32 == -1 && retried["hostPID"] as? Int32 == -1,
            "native retry preserves its cause and clears current host identity")
        let c = open(); defer { c.invalidate() }; await handshake(c)
        let third = await wait("same anonymous listener accepts a new connection after retry") { $0["status"] as? String == "connected" && $0["replays"] as? Int == 3 }
        c.invalidate()
        let ended = await wait("remote native invalidation clears the current connection") { $0["status"] as? String == "waitingForHost" && $0["clears"] as? Int == 2 }
        let visible = ended["fixtureHostVisibleToWorkspace"] as? Bool == true
        let observedCause = visible ? "The host process was still running, so it likely closed or replaced the XPC connection." : "The host process exited or became unavailable."
        check((ended["details"] as? String)?.contains("Observed cause: " + observedCause) == true,
            "native invalidation follows actual NSWorkspace visibility, independently of process liveness")
        check(ended["resets"] as? Int == 5 && ended["replays"] as? Int == 3 && ended["attemptCount"] as? Int == 1,
            "native listener retries retain endpoint count and exact lifetime effect counts")
        let traces: [[String: Any]] = [first, second, afterStale, retried, third, ended]
        try! JSONSerialization.data(withJSONObject: traces, options: .sortedKeys).write(to: directory.appendingPathComponent("native-lifecycle-trace.json"))
        try! JSONSerialization.data(withJSONObject: ["status": "passed", "checks": checks, "hostPID": getpid(), "producerPID": pid,
            "expectedLifecycleSnapshots": 26, "nativeLifecycleStates": traces.count], options: .sortedKeys).write(to: directory.appendingPathComponent("result.json"))
        print("Native PIP connection checks: \(checks)")
    }
}
