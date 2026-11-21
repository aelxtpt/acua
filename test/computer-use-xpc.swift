import Carbon
import Foundation
import os
import XPC

private final class Observer: NSObject, ComputerUseXPCForegroundObserver {
    let received = OSAllocatedUnfairLock(initialState: [Data]())
    func receiveForegroundContext(_ data: Data) { received.withLock { $0.append(data) } }
}

// Sender identity attributes are kernel-owned and cannot be populated with
// setAttribute on a newly constructed event. Model receipt in a descriptor
// subclass; no Apple Event is sent and no real audit identity is fabricated.
private final class ReceivedEventFixture: NSAppleEventDescriptor {
    var receivedAttributes = [AEKeyword: NSAppleEventDescriptor]()
    override func attributeDescriptor(forKeyword keyword: AEKeyword) -> NSAppleEventDescriptor? {
        receivedAttributes[keyword] ?? super.attributeDescriptor(forKeyword: keyword)
    }
}

@main enum ComputerUseXPCTests {
    struct Failure: Error { var message: String }

    static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
        print("PASS \(message)")
        fflush(stdout)
    }

    static func poll<T>(_ result: () -> T?) async throws -> T {
        let clock = ContinuousClock()
        let until = clock.now.advanced(by: .seconds(3))
        while clock.now < until {
            if let result = result() { return result }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Failure(message: "XPC callback timed out")
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 3,
           ["--service-pid", "--service-pid-ack", "--service-pid-audio"].contains(CommandLine.arguments[1]),
           let pid = Int32(CommandLine.arguments[2]) {
            let mode = CommandLine.arguments[1]
            try await production(pid, noReply: mode == "--service-pid", testAudio: mode == "--service-pid-audio")
            return
        }
        let document = #"{"id":9223372036854775807,"note":"👩🏽‍💻 café\u0000"}"#
        for (label, encoding, bom): (String, String.Encoding, [UInt8]) in [
            ("UTF-16LE BOM", .utf16LittleEndian, [255, 254]),
            ("UTF-16BE BOM", .utf16BigEndian, [254, 255]),
            ("UTF-32BE BOM", .utf32BigEndian, [0, 0, 254, 255])
        ] {
            let body = try ComputerUseXPC.requestBody(Data(bom) + document.data(using: encoding)!) as? JSON
            try check(intValue(body?["id"]) == Int.max && str(body?["note"]) == "👩🏽‍💻 café\0",
                      "XPC \(label) preserves exact IDs and Unicode")
        }
        do {
            _ = try ComputerUseXPC.requestBody(Data([255, 254, 0, 0]) + document.data(using: .utf32LittleEndian)!)
            throw Failure(message: "XPC accepted a UTF-32LE BOM that the typed decoder rejects")
        } catch DecodingError.dataCorrupted {
            try check(true, "XPC keeps the Foundation UTF-32LE BOM error")
        }
        try ComputerUseXPCBootstrap.validateVersion("AcuaComputerUseNativeBridge-1", clientType: "native_bridge")
        try ComputerUseXPCBootstrap.validateVersion(nil, clientType: "node_repl")
        do {
            try ComputerUseXPCBootstrap.validateVersion("wrong", clientType: "desktop")
            throw Failure(message: "invalid version accepted")
        } catch let error as ServiceError {
            try check(error.code == .incompatibleClientVersion, "bootstrap validates native version variants")
        }
        var token = audit_token_t()
        token.val.1 = geteuid()
        token.val.5 = UInt32(getpid())
        let credentials = try ComputerUseXPCBootstrap.credentials(withUnsafeBytes(of: &token) { Data($0) })
        try check(credentials.pid == getpid() && credentials.uid == geteuid(),
            "bootstrap obtains the PID and effective UID from the audit token")

        var state = ComputerUseXPCForegroundContext(processIdentifier: 42, windowID: 5,
            appName: "Owned", bundleIdentifier: "example.owned", windowTitle: "First")
        let firstDate = Date(timeIntervalSinceReferenceDate: 42)
        var starts = 0
        var stops = 0
        let foreground = ComputerUseForegroundUpdates(start: { updates in
            starts += 1
            updates.publish(starts == 1 ? state : nil, at: firstDate)
        }, stop: { stops += 1 })
        try appleEventRequests(peer: credentials, foreground: foreground)
        try await appleEventAuthorizationBootstrap()
        try await pipBootstraps(foreground)
        let session = ComputerUseXPCSession(peerPID: getpid(), peerUID: geteuid(), handler: { type, data, metadata, files, cancelled in
            if type == "FixtureError" {
                throw NSError(domain: "OwnedFixture", code: 51, userInfo: [
                    NSLocalizedDescriptionKey: "owned NSError", "ownedExtra": true,
                ])
            }
            guard type == "Fixture", data == Data([1]), metadata == Data([2]), files.count == 1, !cancelled() else {
                throw ServiceError(.couldNotGetRequestData, "Fixture input mismatch")
            }
            guard fcntl(files[0].fileDescriptor, F_GETFD) & FD_CLOEXEC != 0 else {
                throw ServiceError(.unknownError, "Duplicated descriptor inherited across exec")
            }
            return files[0].readDataToEndOfFile()
        }, foreground: foreground)
        let connection = NSXPCConnection(listenerEndpoint: session.endpoint)
        connection.remoteObjectInterface = ComputerUseXPC.interface()
        connection.activate()
        defer { connection.invalidate(); session.invalidate() }
        let io = OSAllocatedUnfairLock(initialState: (false, Optional<Data>.none, Optional<NSError>.none))
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in io.withLock { $0 = (true, nil, error as NSError) } }
        guard let proxy = proxy as? ComputerUseXPCProtocol else { throw Failure(message: "No XPC proxy") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cua-xpc-owned-\(UUID())")
        try Data([3, 4]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try FileHandle(forReadingFrom: url)
        let descriptors = xpc_array_create(nil, 0)
        xpc_array_append_value(descriptors, xpc_fd_create(file.fileDescriptor)!)
        proxy.sendRequest(typeName: "Fixture", requestData: Data([1]), agentMetadataData: Data([2]),
                          fileDescriptors: descriptors as! ComputerUseXPCFileArray) { data, error in
            io.withLock { $0 = (true, data, error) }
        }
        let success = try await poll { io.withLock { $0.0 ? ($0.1, $0.2) : nil } }
        try check(success.0 == Data([3, 4]) && success.1 == nil,
            "native XPC interface transfers file descriptors and request metadata")

        io.withLock { $0 = (false, nil, nil) }
        proxy.sendRequest(typeName: "FixtureError", requestData: Data("{}".utf8), agentMetadataData: nil,
                          fileDescriptors: descriptors as! ComputerUseXPCFileArray) { data, error in
            io.withLock { $0 = (true, data, error) }
        }
        let failure = try await poll { io.withLock { $0.0 ? ($0.1, $0.2) : nil } }
        try check(failure.0 == nil && failure.1?.domain == "ComputerUseIPCXPC" && failure.1?.code == -10005 &&
                  failure.1?.userInfo.keys.sorted() == [NSLocalizedDescriptionKey] &&
                  failure.1?.localizedDescription.contains("Error Domain=OwnedFixture Code=51") == true,
            "native XPC normalizes unexpected request failures without forwarding their userInfo dictionary")

        xpc_array_append_value(descriptors, xpc_string_create("not a descriptor"))
        io.withLock { $0 = (false, nil, nil) }
        proxy.sendRequest(typeName: "Fixture", requestData: nil, agentMetadataData: nil,
                          fileDescriptors: descriptors as! ComputerUseXPCFileArray) { data, error in
            io.withLock { $0 = (true, data, error) }
        }
        let rejected = try await poll { io.withLock { $0.0 ? ($0.1, $0.2) : nil } }
        try check(rejected.0 == nil && rejected.1?.domain == "ComputerUseIPCXPC" && rejected.1?.code == -10025 &&
                  rejected.1?.localizedDescription == "attachment file descriptors were invalid",
            "native XPC rejects an array with invalid descriptor entries using the invalid-request code and message")

        func subscribe(_ id: NSUUID, _ observer: Observer) async throws -> Data {
            let subscribed = OSAllocatedUnfairLock(initialState: (false, Optional<NSError>.none))
            proxy.subscribeToForegroundContext(id: id, observer: observer) { error in
                subscribed.withLock { $0 = (true, error) }
            }
            let result = try await poll { subscribed.withLock { $0.0 ? $0 : nil } }
            if let error = result.1 { throw error }
            return try await poll { observer.received.withLock { $0.first } }
        }
        let observer = Observer()
        let id = NSUUID()
        let initial = try await subscribe(id, observer)
        let first = asDict(jsonObject(initial)?["context"])
        try check(first?["windowTitle"] as? String == "First" && first?["windowID"] as? Int == 5,
            "foreground observer receives the initial native update shape")

        let secondID = NSUUID()
        let secondObserver = Observer()
        _ = try await subscribe(secondID, secondObserver)
        foreground.publish(state, at: firstDate.addingTimeInterval(1))
        let replacement = Observer()
        let cached = try await subscribe(id, replacement)
        try check(starts == 1 && stops == 0 && jsonObject(cached)?["observedAt"] as? Double == 42 &&
                  observer.received.withLock { $0.count } == 1,
            "duplicate subscription replaces the observer and replays the deduplicated sample with its original time")

        state.windowTitle = "First change"
        foreground.publish(state, at: firstDate.addingTimeInterval(2))
        state.windowTitle = "Discarded"
        foreground.publish(state, at: firstDate.addingTimeInterval(2))
        state.windowTitle = "Second"
        foreground.publish(state, at: firstDate.addingTimeInterval(3))
        let newest = try await poll {
            replacement.received.withLock { $0.first { asDict(jsonObject($0)?["context"])?["windowTitle"] as? String == "Second" } }
        }
        try check(jsonObject(newest)?["observedAt"] as? Double == 45 &&
                  replacement.received.withLock {
                      !$0.contains { asDict(jsonObject($0)?["context"])?["windowTitle"] as? String == "Discarded" }
                  } && observer.received.withLock { $0.count } == 1,
            "foreground stream keeps the newest buffered sample and sends the event time")

        foreground.publish(nil, at: firstDate.addingTimeInterval(4))
        let hidden = try await poll {
            secondObserver.received.withLock { $0.first { jsonObject($0)?["observedAt"] as? Double == 46 } }
        }
        try check(jsonObject(hidden)?["context"] == nil && starts == 1, "unreadable foreground omits the context for shared subscribers")
        proxy.unsubscribeFromForegroundContext(id: secondID)
        proxy.unsubscribeFromForegroundContext(id: id)
        _ = try await poll { stops == 1 ? true : nil }
        let stoppedCount = replacement.received.withLock { $0.count }
        foreground.publish(state, at: firstDate.addingTimeInterval(5))
        let restartedID = NSUUID()
        let restarted = try await subscribe(restartedID, Observer())
        try check(starts == 2 && jsonObject(restarted)?["context"] == nil && replacement.received.withLock { $0.count } == stoppedCount,
            "last unsubscribe stops the shared monitor and the next subscription starts fresh")
        for _ in 1..<16 { _ = try await subscribe(NSUUID(), Observer()) }
        do {
            _ = try await subscribe(NSUUID(), Observer())
            throw Failure(message: "subscription cap exceeded")
        } catch let error as NSError where error.domain == "ComputerUseIPCXPC" {
            try check(error.localizedDescription.contains("(16 per connection)"), "XPC caps distinct subscription IDs at 16")
        }
        _ = try await subscribe(restartedID, Observer())
        try check(starts == 2, "XPC allows replacing a subscription at the cap")

        let denied = ComputerUseXPCSession(peerPID: getpid() + 1, peerUID: geteuid(), handler: { _, _, _, _, _ in
            throw Failure(message: "foreign PID reached handler")
        }, foreground: foreground, foregroundOnly: true)
        defer { denied.invalidate() }
        let foreign = NSXPCConnection(listenerEndpoint: denied.endpoint)
        foreign.remoteObjectInterface = ComputerUseXPC.interface()
        foreign.activate()
        defer { foreign.invalidate() }
        let blocked = OSAllocatedUnfairLock(initialState: false)
        let foreignProxy = foreign.remoteObjectProxyWithErrorHandler { _ in blocked.withLock { $0 = true } }
        let empty = xpc_array_create(nil, 0) as! ComputerUseXPCFileArray
        (foreignProxy as? ComputerUseXPCProtocol)?.sendRequest(typeName: "Fixture", requestData: nil,
            agentMetadataData: nil, fileDescriptors: empty) { _, _ in }
        _ = try await poll { blocked.withLock { $0 ? true : nil } }
        try check(true, "foreground-only endpoint rejects a connection from a different PID")

        try machReply(session.endpoint)
        connection.invalidate()
        _ = try await poll { stops == 2 ? true : nil }
        try check(session.isInvalidated, "XPC disconnect cancels all foreground streams")
        try await sessionAdmissionAndLifecycle()
    }

    @MainActor private static func sessionAdmissionAndLifecycle() async throws {
        typealias ReplyState = OSAllocatedUnfairLock<(Bool, Data?, NSError?)>
        typealias Client = (connection: NSXPCConnection, proxy: ComputerUseXPCProtocol, state: ReplyState)
        func connect(_ session: ComputerUseXPCSession) throws -> Client {
            let state = ReplyState(initialState: (false, nil, nil))
            let connection = NSXPCConnection(listenerEndpoint: session.endpoint)
            connection.remoteObjectInterface = ComputerUseXPC.interface()
            connection.activate()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                state.withLock { $0 = (true, nil, error as NSError) }
            }) as? ComputerUseXPCProtocol else { throw Failure(message: "Missing fixture proxy") }
            return (connection, proxy, state)
        }
        func request(_ client: Client, files: ComputerUseXPCFileArray? = nil) async throws -> (Data?, NSError?) {
            client.state.withLock { $0 = (false, nil, nil) }
            client.proxy.sendRequest(typeName: "OwnedFixture", requestData: Data([7]), agentMetadataData: nil,
                fileDescriptors: files ?? xpc_array_create(nil, 0) as! ComputerUseXPCFileArray) { data, error in
                client.state.withLock { $0 = (true, data, error) }
            }
            return try await poll { client.state.withLock { $0.0 ? ($0.1, $0.2) : nil } }
        }
        let foreground = ComputerUseForegroundUpdates(start: { updates in
            updates.publish(nil, at: Date(timeIntervalSinceReferenceDate: 10))
        }, stop: {})
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let ended = OSAllocatedUnfairLock(initialState: 0)
        let full = ComputerUseXPCSession(peerPID: getpid() + 1, peerUID: geteuid() + 1, handler: { _, _, _, _, cancelled in
            guard !cancelled() else { throw Failure(message: "Surviving connection was cancelled") }
            return calls.withLock { $0 += 1; return Data([UInt8($0)]) }
        }, foreground: foreground, finished: { ended.withLock { $0 += 1 } })
        defer { full.invalidate() }
        let first = try connect(full), second = try connect(full)
        defer { first.connection.invalidate(); second.connection.invalidate() }
        let a = try await request(first), b = try await request(second)
        try check(a.0 == Data([1]) && a.1 == nil, "full endpoint admits a different PID and UID by possession of the endpoint")
        try check(b.0 == Data([2]) && b.1 == nil, "full session admits multiple connections")
        first.connection.invalidate()
        _ = try await poll { ended.withLock { $0 == 2 ? true : nil } }
        try check(full.isInvalidated, "first disconnect closes the listener and Foundation invalidates both connections")
        let c = try await request(second)
        try check(c.0 == nil && c.1 != nil && calls.withLock { $0 == 2 },
                  "a closed listener cannot deliver new commands through its former connections")

        let running = OSAllocatedUnfairLock(initialState: (started: false, done: false, cancelled: true))
        let release = DispatchSemaphore(value: 0)
        let active = ComputerUseXPCSession(peerPID: getpid(), peerUID: geteuid(), handler: { _, _, _, _, cancelled in
            running.withLock { $0.started = true }
            guard release.wait(timeout: .now() + 3) == .success else { throw Failure(message: "Owned work was not released") }
            running.withLock { $0.done = true; $0.cancelled = cancelled() }
            return Data([1])
        }, foreground: foreground)
        defer { release.signal(); active.invalidate() }
        let activeClient = try connect(active)
        activeClient.proxy.sendRequest(typeName: "OwnedFixture", requestData: nil, agentMetadataData: nil,
            fileDescriptors: xpc_array_create(nil, 0) as! ComputerUseXPCFileArray) { _, _ in }
        _ = try await poll { running.withLock { $0.started ? true : nil } }
        activeClient.connection.invalidate()
        _ = try await poll { active.isInvalidated ? true : nil }
        release.signal()
        _ = try await poll { running.withLock { $0.done ? true : nil } }
        try check(running.withLock { !$0.cancelled }, "listener closure does not cancel already running request work")

        let blockedCalls = OSAllocatedUnfairLock(initialState: 0)
        let restricted = ComputerUseXPCSession(peerPID: getpid(), peerUID: geteuid() + 1, handler: { _, _, _, _, _ in
            blockedCalls.withLock { $0 += 1 }; return Data([9])
        }, foreground: foreground, foregroundOnly: true)
        defer { restricted.invalidate() }
        let client = try connect(restricted)
        defer { client.connection.invalidate() }
        let rejected = try await request(client)
        try check(rejected.0 == nil && rejected.1?.code == -10000 && rejected.1?.localizedDescription == "Sender process is not authenticated" &&
                  blockedCalls.withLock { $0 == 0 }, "restricted session rejects commands before invoking the handler")
        let received = Observer(), complete = ReplyState(initialState: (false, nil, nil))
        client.proxy.subscribeToForegroundContext(id: NSUUID(), observer: received) { error in
            complete.withLock { $0 = (true, nil, error) }
        }
        _ = try await poll { complete.withLock { $0.0 && $0.2 == nil ? true : nil } }
        _ = try await poll { received.received.withLock { !$0.isEmpty ? true : nil } }
        try check(true, "restricted same-PID session permits foreground subscription without a UID comparison")
        let invalid = xpc_array_create(nil, 0)
        xpc_array_append_value(invalid, xpc_string_create("invalid"))
        let invalidResult = try await request(client, files: (invalid as! ComputerUseXPCFileArray))
        try check(invalidResult.1?.code == -10025 && blockedCalls.withLock { $0 == 0 },
                  "file descriptor validation precedes restricted command rejection")
    }

    @MainActor private static func pipBootstraps(_ foreground: ComputerUseForegroundUpdates) async throws {
        var enabled = false
        var gateReads = 0
        let pip = RemoteHostedPIPService {
            gateReads += 1
            return enabled
        }
        let bootstrap = ComputerUseXPCBootstrap(allow: { _ in false }, dispatch: { _, _, _, _, _, _, _, _ in Data() },
            foreground: foreground, pipEndpoint: pip.endpoint)
        let event = NSAppleEventDescriptor(eventClass: ComputerUseXPCBootstrap.eventClass,
            eventID: ComputerUseXPCBootstrap.pipBootstrapNoReply, targetDescriptor: nil, returnID: -1, transactionID: 0)
        let deniedReply = NSAppleEventDescriptor.record()
        bootstrap.receivePIP(event, reply: deniedReply)
        try check(deniedReply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value == -10017 && gateReads == 0,
                  "PiP bootstrap authenticates before consulting the publisher")
        do {
            _ = try bootstrap.endpointForPIPEvent(event)
            throw Failure(message: "PiP accepted a missing client version")
        } catch let error as ServiceError {
            try check(error.code == .incompatibleClientVersion && gateReads == 0, "PiP bootstrap validates the client version before allocation")
        }
        event.setParam(NSAppleEventDescriptor(string: kApiVersion), forKeyword: ComputerUseXPCBootstrap.versionProperty)
        do {
            _ = try bootstrap.endpointForPIPEvent(event)
            throw Failure(message: "disabled PiP exposed an endpoint")
        } catch let error as ServiceError {
            let failure = ComputerUseXPC.requestError(error)
            try withPort { port in
                try check(ComputerUseXPCMachReply.send(nil, port: port, noReply: true, error: failure),
                          "one-way PiP bootstrap publishes an error to the owned Mach port")
                let payload = try receive(port)
                let message = xpc_dictionary_get_string(payload, "errorMessage").map { String(cString: $0) }
                try check(xpc_dictionary_get_int64(payload, "errorCode") == -10005 &&
                          message == "Remote hosted PiP is unavailable." && xpc_dictionary_get_value(payload, "endpoint") == nil,
                          "disabled PiP bootstrap returns its error and no endpoint")
            }
        }
        enabled = true
        pip.prepare()
        enabled = false
        let endpoint = try bootstrap.endpointForPIPEvent(event)
        try check(gateReads == 2, "PiP retries the gate until enabled and retains the publisher afterward")
        let transferred = try withPort { port in
            try check(ComputerUseXPCMachReply.send(endpoint, port: port, noReply: true),
                      "enabled PiP transfers the native producer endpoint over Mach")
            return try decodeEndpoint(receive(port))
        }
        let connection = NSXPCConnection(listenerEndpoint: transferred)
        connection.remoteObjectInterface = RemoteHostedPIPXPC.producerInterface()
        connection.activate()
        defer { connection.invalidate() }
        let state = OSAllocatedUnfairLock(initialState: (false, Optional<NSError>.none))
        guard let producer = connection.remoteObjectProxyWithErrorHandler({ error in
            state.withLock { $0 = (true, error as NSError) }
        }) as? RemoteHostedPIPContentProducerXPCProtocol else { throw Failure(message: "PiP producer proxy unavailable") }
        producer.connect { error in state.withLock { $0 = (true, error) } }
        let result = try await poll { state.withLock { $0.0 ? $0 : nil } }
        try check(result.1 == nil, "PiP host connects to the publisher through the transferred endpoint")
    }

    @MainActor private static func appleEventRequests(peer: PeerAuditCredentials,
                                                     foreground: ComputerUseForegroundUpdates) throws {
        let firstContext = SenderRequestContext(senderPID: peer.pid, responsibleIdentity: .init(bundleID: "first-owner"), ancestorIdentities: [])
            .withAppleEventMetadata(clientType: nil, version: kApiVersion)
        let secondContext = SenderRequestContext(senderPID: peer.pid, responsibleIdentity: .init(bundleID: "second-owner"), ancestorIdentities: [])
        var resolveCount = 0, phase = 0
        let observedContexts = OSAllocatedUnfairLock(initialState: [SenderRequestContext?]())
        let bootstrap = ComputerUseXPCBootstrap(allow: { $0.auditToken == peer.auditToken },
            dispatch: { sender, context, type, request, metadata, files, returnActionAppSnapshot, cancelled in
                observedContexts.withLock { $0.append(context) }
                guard sender.pid == peer.pid, type == "Fixture", request == Data([1, 2]),
                      metadata == Data([3]), files.isEmpty, !cancelled() else {
                    throw Failure(message: "Apple Event dispatch arguments were not preserved")
                }
                return returnActionAppSnapshot ? Data([4, 5]) : Data([6, 7])
            }, foreground: foreground, resolveSenderContext: { _ in
                resolveCount += 1
                return phase == 0 ? firstContext : secondContext
            })
        let event = NSAppleEventDescriptor(eventClass: ComputerUseXPCBootstrap.eventClass,
            eventID: ComputerUseXPCBootstrap.requestEvent, targetDescriptor: nil, returnID: -1, transactionID: 0)
        func descriptor(_ data: Data) throws -> NSAppleEventDescriptor {
            guard let descriptor = NSAppleEventDescriptor(descriptorType: DescType(typeData), data: data) else {
                throw Failure(message: "Could not encode fixture Apple Event data")
            }
            return descriptor
        }
        func checkFailure(_ code: Int, _ message: String) throws {
            do {
                _ = try bootstrap.requestJob(event, authenticatedPeer: peer)
                throw Failure(message: message)
            } catch let error as ServiceError {
                let reply = NSAppleEventDescriptor.record()
                ComputerUseXPCBootstrap.writeRequestReply(.failure(ComputerUseXPC.requestError(error)), to: reply)
                try check(reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value == Int32(code) &&
                          reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue == error.message &&
                          reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)) == nil, message)
            }
        }
        let noTokenReply = NSAppleEventDescriptor.record()
        bootstrap.receiveRequest(event, reply: noTokenReply)
        try check(noTokenReply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value == -10017,
                  "injected token-only transport fixture requires a sender identity")
        do {
            _ = try ComputerUseXPCBootstrap.credentials(peer.auditToken, senderPID: peer.pid + 1)
            throw Failure(message: "Apple Event accepted a mismatched sender PID")
        } catch let error as ServiceError {
            try check(error.code == .senderProcessNotAuthenticated,
                      "Apple Event request rejects a sender PID that disagrees with its token")
        }
        try checkFailure(-10013, "Apple Event request checks client version before decoding the body")
        event.setParam(NSAppleEventDescriptor(string: kApiVersion), forKeyword: ComputerUseXPCBootstrap.versionProperty)
        try checkFailure(-10001, "Apple Event request rejects missing request bytes")
        event.setParam(try descriptor(Data([1, 2])), forKeyword: ComputerUseXPCBootstrap.requestDataProperty)
        try checkFailure(-10002, "Apple Event request rejects missing request type")
        event.setParam(NSAppleEventDescriptor(string: "Fixture"), forKeyword: ComputerUseXPCBootstrap.requestTypeProperty)
        event.setParam(try descriptor(Data([3])), forKeyword: ComputerUseXPCBootstrap.requestMetadataProperty)
        try check(resolveCount == 3, "authenticated Apple Event identity resolution precedes envelope decoding")
        let job = try bootstrap.requestJob(event, authenticatedPeer: peer)
        phase = 1
        let reply = NSAppleEventDescriptor.record()
        ComputerUseXPCBootstrap.writeRequestReply(.success(try job()), to: reply)
        let data = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
        try check(data?.descriptorType == DescType(typeData) && data?.data == Data([4, 5]),
                  "Apple Event request forwards the raw payload and returns a typed direct object")
        _ = try job()
        try check(resolveCount == 4 && observedContexts.withLock { $0 == [firstContext, firstContext] },
                  "prepared Apple Event work retains its captured sender identity")
        event.setParam(NSAppleEventDescriptor(string: "node_repl"), forKeyword: ComputerUseXPCBootstrap.clientTypeProperty)
        let nodeRequest = try bootstrap.requestJob(event, authenticatedPeer: peer)
        try check(try nodeRequest() == Data([6, 7]), "the native node_repl route disables post-action capture")
        event.setParam(NSAppleEventDescriptor(string: "other"), forKeyword: ComputerUseXPCBootstrap.clientTypeProperty)
        let genericRequest = try bootstrap.requestJob(event, authenticatedPeer: peer)
        try check(try genericRequest() == Data([4, 5]), "unrecognized native client types retain post-action capture")
        try check(resolveCount == 6 && observedContexts.withLock { $0 == [firstContext, firstContext,
            secondContext.withAppleEventMetadata(clientType: "node_repl", version: kApiVersion),
            secondContext.withAppleEventMetadata(clientType: "other", version: kApiVersion)] },
                  "new Apple Events resolve new identities without replacing prepared work")

    }

    @MainActor private static func appleEventAuthorizationBootstrap() async throws {
        var fullContext = false
        let metadata = OSAllocatedUnfairLock(initialState: [(SenderRequestContext?, Bool)]())
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let foreground = ComputerUseForegroundUpdates(start: { updates in
            updates.publish(nil, at: Date(timeIntervalSinceReferenceDate: 20))
        }, stop: {})
        let auth = SenderAuthorization(ownTeam: { "OWN" }, peerTeam: { _ in nil }, ancestors: { _ in [] }, processTeam: { _ in "OWN" })
        let bootstrap = ComputerUseXPCBootstrap(allow: { _ in false }, dispatch: { _, context, _, _, _, _, returnsAppSnapshot, _ in
            metadata.withLock { $0.append((context, returnsAppSnapshot)) }
            guard context?.foregroundOnly == false else { throw Failure(message: "restricted work reached dispatch") }
            calls.withLock { $0 += 1 }; return Data([42])
        }, foreground: foreground, resolveSenderContext: { _ in
            identityRefreshes.withLock { $0 += 1 }; return nil
        }, authorizeEvent: { sender in
            try auth.authorizeAppleEventSignedClient(sender, isDesignatedHost: { _ in false }, resolveContext: { pid in
                .init(senderPID: pid, responsibleIdentity: nil,
                      ancestorIdentities: fullContext ? [.init(team: "OWN")] : [])
            })
        })
        defer { bootstrap.stop() }
        func event(_ id: AEEventID = ComputerUseXPCBootstrap.bootstrapNoReply) -> ReceivedEventFixture {
            let event = ReceivedEventFixture(eventClass: ComputerUseXPCBootstrap.eventClass,
                eventID: id, targetDescriptor: nil, returnID: -1, transactionID: 0)
            event.receivedAttributes[AEKeyword(keySenderPIDAttr)] = NSAppleEventDescriptor(int32: getpid())
            event.setParam(NSAppleEventDescriptor(string: kApiVersion), forKeyword: ComputerUseXPCBootstrap.versionProperty)
            return event
        }
        let input = event()
        let authenticated = try bootstrap.authenticatedSender(input)
        try check(authenticated.peer.pid == getpid() && authenticated.peer.auditToken.isEmpty && authenticated.context?.foregroundOnly == true && authenticated.context?.clientMetadata.mcpRuntime == .legacyMCP,
                  "production-style authorizer supports signed PID fallback without an audit token")
        let raw = event(ComputerUseXPCBootstrap.requestEvent)
        raw.setParam(NSAppleEventDescriptor(string: "Fixture"), forKeyword: ComputerUseXPCBootstrap.requestTypeProperty)
        guard let body = NSAppleEventDescriptor(descriptorType: DescType(typeData), data: Data([1])) else { throw Failure(message: "fixture descriptor") }
        raw.setParam(body, forKeyword: ComputerUseXPCBootstrap.requestDataProperty)
        do {
            let job = try bootstrap.requestJob(raw, authenticatedPeer: authenticated.peer, senderContext: authenticated.context)
            _ = try job(); throw Failure(message: "Restricted legacy request was dispatched")
        } catch let error as ServiceError {
            try check(error.code == .senderProcessNotAuthenticated && calls.withLock { $0 == 0 },
                      "restricted legacy Apple Event work is refused before dispatch")
        }
        let pip = event(ComputerUseXPCBootstrap.pipBootstrap)
        pip.setParam(NSAppleEventDescriptor(string: "invalid"), forKeyword: ComputerUseXPCBootstrap.versionProperty)
        let pipReply = NSAppleEventDescriptor.record()
        bootstrap.receivePIP(pip, reply: pipReply)
        try check(pipReply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber))?.int32Value == -10000,
                  "restricted PiP bootstrap is denied before version or endpoint work")
        func endpoint(clientType: String? = nil, version: String = kApiVersion) throws -> NSXPCListenerEndpoint {
            try withPort { port in
                let request = event()
                request.setParam(NSAppleEventDescriptor(string: version), forKeyword: ComputerUseXPCBootstrap.versionProperty)
                if let clientType { request.setParam(NSAppleEventDescriptor(string: clientType), forKeyword: ComputerUseXPCBootstrap.clientTypeProperty) }
                let bytes = withUnsafeBytes(of: port) { Data($0) }
                guard let replyPort = NSAppleEventDescriptor(descriptorType: DescType(typeMachPort), data: bytes) else { throw Failure(message: "reply port descriptor") }
                request.receivedAttributes[AEKeyword(keyReplyPortAttr)] = replyPort
                bootstrap.receive(request, reply: NSAppleEventDescriptor.record())
                return try decodeEndpoint(receive(port))
            }
        }
        typealias State = OSAllocatedUnfairLock<(Bool, Data?, NSError?)>
        func client(_ endpoint: NSXPCListenerEndpoint) throws -> (NSXPCConnection, ComputerUseXPCProtocol, State) {
            let state = State(initialState: (false, nil, nil))
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            connection.remoteObjectInterface = ComputerUseXPC.interface(); connection.activate()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in state.withLock { $0 = (true, nil, error as NSError) } }) as? ComputerUseXPCProtocol else {
                throw Failure(message: "bootstrap proxy")
            }
            return (connection, proxy, state)
        }
        func send(_ client: (NSXPCConnection, ComputerUseXPCProtocol, State)) async throws -> (Data?, NSError?) {
            client.2.withLock { $0 = (false, nil, nil) }
            client.1.sendRequest(typeName: "Fixture", requestData: Data([1]), agentMetadataData: nil,
                fileDescriptors: xpc_array_create(nil, 0) as! ComputerUseXPCFileArray) { data, error in client.2.withLock { $0 = (true, data, error) } }
            return try await poll { client.2.withLock { $0.0 ? ($0.1, $0.2) : nil } }
        }
        let restricted = try client(endpoint())
        defer { restricted.0.invalidate() }
        let denied = try await send(restricted)
        try check(denied.0 == nil && denied.1?.code == -10000 && calls.withLock { $0 == 0 },
                  "bootstrap issues a subscription-only endpoint that refuses commands")
        let observer = Observer(), subscription = State(initialState: (false, nil, nil))
        restricted.1.subscribeToForegroundContext(id: NSUUID(), observer: observer) { error in subscription.withLock { $0 = (true, nil, error) } }
        _ = try await poll { subscription.withLock { $0.0 && $0.2 == nil ? true : nil } }
        _ = try await poll { observer.received.withLock { !$0.isEmpty ? true : nil } }
        try check(true, "restricted bootstrap endpoint delivers owned foreground updates")
        fullContext = true
        let full = try client(endpoint(clientType: "node_repl", version: AppleEventAuthorization.nativeBridgeVersion))
        defer { full.0.invalidate() }
        let delivered = try await send(full)
        try check(delivered.0 == Data([42]) && delivered.1 == nil && calls.withLock { $0 == 1 },
                "bootstrap issues a full endpoint after context authorization")
        try check(metadata.withLock { $0.count == 1 && $0[0].0?.clientMetadata.clientType == .nodeRepl && $0[0].0?.clientMetadata.mcpRuntime == nil && !$0[0].1 },
                  "full endpoint retains native-bridge client metadata and suppresses node action capture")
        let stillDenied = try await send(restricted)
        try check(stillDenied.1?.code == -10000 && calls.withLock { $0 == 1 },
                  "a later full grant does not upgrade an earlier restricted endpoint")
        try check(identityRefreshes.withLock { $0 == 0 }, "bootstrap retains the authorizer's snapshot without resolving identity again")
    }

    private static let identityRefreshes = OSAllocatedUnfairLock(initialState: 0)

    private static func machReply(_ endpoint: NSXPCListenerEndpoint) throws {
        try withPort { port in
            try check(ComputerUseXPCMachReply.send(endpoint, port: port, noReply: true), "bootstrap sends an endpoint over an owned Mach port")
            let payload = try receive(port)
            let received = xpc_dictionary_get_value(payload, "endpoint")
            try check(received.map(xpc_get_type) == XPC_TYPE_ENDPOINT, "Mach bootstrap dictionary carries the XPC endpoint type")
        }
        try withPort { port in
            let sent = OSAllocatedUnfairLock(initialState: false)
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                sent.withLock { $0 = ComputerUseXPCMachReply.send(endpoint, port: port, noReply: false) }
                done.signal()
            }
            let payload = try receive(port)
            try acknowledge(payload)
            try check(done.wait(timeout: .now() + 3) == .success && sent.withLock { $0 },
                "acknowledged bootstrap completes after the client replies to the Mach message")
        }
    }

    private static func withPort<T>(_ body: (mach_port_t) throws -> T) throws -> T {
        let task = mach_task_self_
        var port: mach_port_t = 0
        guard mach_port_allocate(task, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), &port) == KERN_SUCCESS else {
            throw Failure(message: "allocate fixture port")
        }
        defer {
            mach_port_mod_refs(task, port, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), -1)
            mach_port_deallocate(task, port)
        }
        guard mach_port_insert_right(task, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS else {
            throw Failure(message: "fixture receive pipe")
        }
        return try body(port)
    }

    private static func receive(_ port: mach_port_t) throws -> ComputerUseXPCFileArray {
        guard let image = dlopen(nil, RTLD_LAZY), let symbol = dlsym(image, "xpc_pipe_receive") else {
            throw Failure(message: "fixture receive pipe")
        }
        typealias Receive = @convention(c) (mach_port_t, UnsafeMutablePointer<Unmanaged<AnyObject>?>) -> Int32
        var raw: Unmanaged<AnyObject>?
        guard unsafeBitCast(symbol, to: Receive.self)(port, &raw) == 0,
              let payload = raw?.takeRetainedValue() as? ComputerUseXPCFileArray else {
            throw Failure(message: "receive fixture endpoint")
        }
        return payload
    }

    private static func acknowledge(_ payload: ComputerUseXPCFileArray) throws {
        typealias Reply = @convention(c) (AnyObject) -> Int32
        guard let image = dlopen(nil, RTLD_LAZY), let symbol = dlsym(image, "xpc_pipe_routine_reply"),
              let reply = xpc_dictionary_create_reply(payload),
              unsafeBitCast(symbol, to: Reply.self)(reply) == 0 else {
            throw Failure(message: "acknowledge fixture endpoint")
        }
    }

    private static func decodeEndpoint(_ payload: ComputerUseXPCFileArray) throws -> NSXPCListenerEndpoint {
        guard let raw = xpc_dictionary_get_value(payload, "endpoint"), xpc_get_type(raw) == XPC_TYPE_ENDPOINT else {
            throw Failure(message: "bootstrap returned code \(xpc_dictionary_get_int64(payload, "errorCode"))")
        }
        let result = NSXPCListenerEndpoint()
        let selector = NSSelectorFromString("_setEndpoint:")
        guard result.responds(to: selector), let method = result.method(for: selector) else {
            throw Failure(message: "native endpoint setter is unavailable")
        }
        unsafeBitCast(method, to: (@convention(c) (AnyObject, Selector, AnyObject) -> Void).self)(result, selector, raw)
        return result
    }

    @MainActor
    private static func production(_ pid: pid_t, noReply: Bool, testAudio: Bool) async throws {
        let endpoint = try withPort { port -> NSXPCListenerEndpoint in
            let target = NSAppleEventDescriptor(processIdentifier: pid)
            let event = NSAppleEventDescriptor(eventClass: ComputerUseXPCBootstrap.eventClass,
                eventID: noReply ? ComputerUseXPCBootstrap.bootstrapNoReply : ComputerUseXPCBootstrap.bootstrap,
                targetDescriptor: target, returnID: -1, transactionID: 0)
            event.setParam(NSAppleEventDescriptor(string: kApiVersion), forKeyword: ComputerUseXPCBootstrap.versionProperty)
            let portData = withUnsafeBytes(of: port) { Data($0) }
            guard let descriptor = NSAppleEventDescriptor(descriptorType: DescType(typeMachPort), data: portData) else {
                throw Failure(message: "encode Mach reply descriptor")
            }
            event.setAttribute(descriptor, forKeyword: AEKeyword(keyReplyPortAttr))
            let mode = noReply ? kAENoReply : kAEWaitReply
            let options = NSAppleEventDescriptor.SendOptions(rawValue: UInt(mode | kAENeverInteract | kAEDoNotPromptForUserConsent))
            let reply = try event.sendEvent(options: options, timeout: 3)
            if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
                throw Failure(message: "Apple event bootstrap returned code \(error.int32Value)")
            }
            let payload = try receive(port)
            if !noReply { try acknowledge(payload) }
            return try decodeEndpoint(payload)
        }
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = ComputerUseXPC.interface()
        connection.activate()
        defer { connection.invalidate() }
        let io = OSAllocatedUnfairLock(initialState: (false, Optional<Data>.none, Optional<NSError>.none))
        let proxy = connection.remoteObjectProxyWithErrorHandler { error in io.withLock { $0 = (true, nil, error as NSError) } }
        guard let proxy = proxy as? ComputerUseXPCProtocol else { throw Failure(message: "No production XPC proxy") }
        if testAudio {
            try await audio(proxy)
            return
        }
        let files = xpc_array_create(nil, 0) as! ComputerUseXPCFileArray
        proxy.sendRequest(typeName: "ComputerUseIPCTurnEndedRequest",
            requestData: Data("{\"threadID\":\"owned-fixture\"}".utf8), agentMetadataData: nil, fileDescriptors: files) { data, error in
                io.withLock { $0 = (true, data, error) }
            }
        let outcome = try await poll { io.withLock { $0.0 ? ($0.1, $0.2) : nil } }
        try check(outcome.1 == nil && outcome.0.flatMap(jsonObject)?.isEmpty == true,
            "production Apple event bootstraps a Mach endpoint and dispatches an XPC request")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cua-xpc-production-\(UUID())")
        try Data("owned".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try FileHandle(forReadingFrom: url)
        xpc_array_append_value(files, xpc_fd_create(file.fileDescriptor)!)
        io.withLock { $0 = (false, nil, nil) }
        let body = Data("{\"planID\":\"A1111111-1111-1111-1111-111111111111\",\"text\":\"owned\"}".utf8)
        proxy.sendRequest(typeName: "ComputerUseIPCMessagesCommitSendRequest", requestData: body,
                          agentMetadataData: nil, fileDescriptors: files) { data, error in
            io.withLock { $0 = (true, data, error) }
        }
        let missing = try await poll { io.withLock { $0.0 ? $0.2 : nil } }
        try check(missing.domain == "ComputerUseIPCXPC" && missing.code == -10027,
            "production XPC commit receives a descriptor and rejects the missing plan before permissions")
    }

    @MainActor static func audio(_ proxy: ComputerUseXPCProtocol) async throws {
        let owner = #"{"session_id":"xpc-audio-fixture"}"#
        let other = #"{"session_id":"xpc-audio-other"}"#
        let start = "ComputerUseIPCStartAudioRecordingRequest"
        let stop = "ComputerUseIPCStopAudioRecordingRequest"
        let files = xpc_array_create(nil, 0) as! ComputerUseXPCFileArray
        func send(_ type: String, _ body: String, _ metadata: String) async throws -> (Data?, NSError?) {
            let result = OSAllocatedUnfairLock(initialState: Optional<(Data?, NSError?)>.none)
            proxy.sendRequest(typeName: type, requestData: Data(body.utf8), agentMetadataData: Data(metadata.utf8),
                              fileDescriptors: files) { data, error in
                result.withLock { $0 = (data, error) }
            }
            return try await poll { result.withLock { $0 } }
        }
        let malformed = try await send(start, #"{"maxDurationMilliseconds":"700"}"#, owner)
        try check(malformed.0 == nil && malformed.1?.domain == "ComputerUseIPCXPC" &&
                  malformed.1?.code == -10005 && malformed.1?.localizedDescription.contains("maxDurationMilliseconds") == true,
                  "audio XPC returns a typed duration decoding error")
        let invalid = try await send(start, #"{"maxDurationMilliseconds":99}"#, owner)
        try check(invalid.0 == nil && invalid.1?.code == -10005 && invalid.1?.localizedDescription == "invalidDuration",
                  "audio XPC preserves the native recorder duration error")
        let started = try await send(start, #"{"maxDurationMilliseconds":700}"#, owner)
        try check(started.1 == nil && started.0.flatMap(jsonObject)?.isEmpty == true,
                  "audio XPC Start returns an empty response object")
        try await Task.sleep(for: .milliseconds(1100))
        let rejected = try await send(stop, "{}", other)
        try check(rejected.0 == nil && rejected.1?.domain == "ComputerUseIPCXPC" &&
                  rejected.1?.code == -10005 && rejected.1?.localizedDescription == "recordingNotOwned",
                  "audio XPC rejects a different session after automatic stop")
        let claimed = try await send(stop, "{}", owner)
        guard claimed.1 == nil, let data = claimed.0 else {
            throw Failure(message: "Audio XPC did not return recording data")
        }
        let url = try JSONDecoder().decode(AudioResponse.self, from: data).url
        guard url.isFileURL else { throw Failure(message: "Audio XPC did not return a file URL") }
        defer { try? FileManager.default.removeItem(at: url) }
        let bytes = try Data(contentsOf: url)
        try check(bytes.count > 44 && bytes.prefix(4) == Data("RIFF".utf8) && bytes[8..<12] == Data("WAVE".utf8),
                  "audio XPC returns an existing WAV after automatic stop")
        let consumed = try await send(stop, "{}", owner)
        try check(consumed.0 == nil && consumed.1?.domain == "ComputerUseIPCXPC" &&
                  consumed.1?.code == -10005 && consumed.1?.localizedDescription == "noActiveRecording",
                  "audio XPC does not deliver the WAV twice")

        let turnOwner = #"{"session_id":"xpc-audio-fixture","turn_id":"audio-turn"}"#
        let turnStarted = try await send(start, #"{"maxDurationMilliseconds":5000}"#, turnOwner)
        try check(turnStarted.1 == nil, "audio XPC starts a recording owned by a turn")
        let turnEnded = try await send("ComputerUseIPCTurnEndedRequest",
                                       #"{"threadID":"xpc-audio-fixture","turnID":"audio-turn"}"#, owner)
        let discarded = try await send(stop, "{}", owner)
        try check(turnEnded.1 == nil && turnEnded.0.flatMap(jsonObject)?.isEmpty == true &&
                  discarded.1?.localizedDescription == "noActiveRecording",
                  "audio XPC discards an unclaimed recording on turn end")
    }

    private struct AudioResponse: Decodable { let url: URL }
}
