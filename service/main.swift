import AppKit
import Foundation
import Darwin
import ImageIO

// A disconnected peer must become an I/O error, never a process-wide exit.
signal(SIGPIPE, SIG_IGN)

// Establish a WindowServer connection: ScreenCaptureKit and NSWorkspace need AppKit.
let serviceApplication = NSApplication.shared
serviceApplication.setActivationPolicy(.accessory)
// Warm the software cursor so the first action shows it immediately.
_ = CursorOverlay.shared

// MARK: - Request dispatch

private final class ComputerUseSessionTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var endedTurnIDs: [String: Date] = [:]

    func recordEnd(_ turnID: String?, now: Date = .now) {
        guard let turnID, !turnID.isEmpty else { return }
        lock.withLock {
            endedTurnIDs = endedTurnIDs.filter { $0.value > now }
            endedTurnIDs[turnID] = now.addingTimeInterval(300)
        }
    }

    func hasEnded(_ turnID: String, now: Date = .now) -> Bool {
        lock.withLock { endedTurnIDs[turnID].map { $0 > now } ?? false }
    }
}


enum Dispatch {
    static var requestActivity = NativeRequestActivity.make()
    private static let agentTurns = ComputerUseSessionTracker()
    @MainActor private static weak var pipService: RemoteHostedPIPService?
    @MainActor private static var pipController: RemoteHostedPIPController?
    @MainActor static weak var idleTimer: ServiceIdleTimer?

    private static func resolvesRequestType(_ type: String) -> Bool {
        DirectRequestType(rawValue: type) != nil || MessagesIPCRoute(rawValue: type) != nil ||
            CalendarOperation.Route(rawValue: type) != nil || TimelineOperation.Route(rawValue: type) != nil
    }

    static func resetsInactivity(for type: String) -> Bool {
        type != DirectRequestType.appPolicy.rawValue && type != DirectRequestType.agentTurnEnded.rawValue &&
            resolvesRequestType(type)
    }

    @MainActor static func installPIP(_ service: RemoteHostedPIPService) {
        pipService = service
        CursorOverlay.shared.observeLocation { point, overlayID, targetID in
            MainActor.assumeIsolated { pip()?.updateCursor(at: point, overlayID: overlayID, targetID: targetID) }
        }
    }

    @MainActor static func removePIPApp(pid: Int32) {
        pipController?.removeApp(pid: pid)
    }

    @MainActor private static func pip() -> RemoteHostedPIPController? {
        if let pipController { return pipController }
        guard let publisher = pipService?.publisher else { return nil }
        let controller = RemoteHostedPIPController(publisher: publisher)
        pipController = controller
        return controller
    }

    @discardableResult
    private static func prepareAgentTurn() throws -> RemoteHostedPIPController.Turn? {
        let metadata = ComputerUseTelemetryContext.snapshot()
        guard let turnID = metadata.agentTurnID else { return nil }
        try requireActiveAgentTurn(turnID)
        guard let threadID = metadata.agentSessionID else { return nil }
        let turn = RemoteHostedPIPController.Turn(threadID: threadID, turnID: turnID)
        DispatchQueue.main.async {
            // The notification can arrive while this block is waiting on the main queue.
            guard !agentTurns.hasEnded(turnID) else { return }
            pip()?.begin(turn)
        }
        return turn
    }

    private static func requireActiveAgentTurn(_ turnID: String?) throws {
        if let turnID, agentTurns.hasEnded(turnID) {
            throw ServiceError(.agentTurnAlreadyEnded,
                "Computer Use is unavailable because the current turn ended. It will work again after the next user message.")
        }
    }

    private static func observePIPWindow(_ snapshot: AXSnapshot, turn: RemoteHostedPIPController.Turn?) {
        guard AcuaSettings.features().remoteHostedPIP, let element = snapshot.windowElement else { return }
        let pid = snapshot.appReference.pid
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let rawWindows = AX.copy(application, kAXWindowsAttribute as String) as? [AnyObject] ?? []
        let main = AX.axElement(AX.copy(application, kAXMainWindowAttribute as String))
        let visible = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
        let visibleIDs = Set(visible.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value })
        func describe(_ window: AXUIElement, parent: CGWindowID? = nil) -> RemoteHostedPIPWindowObservation.Window? {
            guard let id = try? AccessibilityWindowSPI.windowID(window), id != 0 else { return nil }
            let axParent = AX.axElement(AX.copy(window, kAXParentAttribute as String))
            let parentID = parent ?? axParent.flatMap { try? AccessibilityWindowSPI.windowID($0) }
            return .init(id: id, role: AX.string(window, kAXRoleAttribute as String) ?? "",
                         subrole: AX.string(window, kAXSubroleAttribute as String),
                         isModal: AX.copy(window, kAXModalAttribute as String) as? Bool ?? false,
                         parent: parentID, isOnScreen: visibleIDs.contains(id))
        }
        guard let selected = describe(element) else { return }
        var windows = [selected.id: selected]
        let candidates = rawWindows.compactMap(AX.axElement) + (main.map { [$0] } ?? [])
        for window in candidates {
            guard let description = describe(window) else { continue }
            if windows[description.id]?.parent == nil { windows[description.id] = description }
            for sheet in AX.children(window) where AX.string(sheet, kAXRoleAttribute as String) == kAXSheetRole as String {
                if let child = describe(sheet, parent: description.id) { windows[child.id] = child }
            }
        }
        let observation = RemoteHostedPIPWindowObservation(pid: pid, selected: windows[selected.id] ?? selected,
            mainWindowID: main.flatMap { try? AccessibilityWindowSPI.windowID($0) }, windows: windows)
        DispatchQueue.main.async {
            if let turn, agentTurns.hasEnded(turn.turnID) { return }
            pip()?.observe(observation, turn: turn)
        }
    }

    static func handle(_ message: JSON, cancelled: @escaping () -> Bool = { false }, peerPID: Int32? = nil,
                       senderContext: SenderRequestContext? = nil,
                       files: [FileHandle] = [], wireData: Data? = nil,
                       serializationFailed: (Error) -> Void = { _ in }) -> JSON {
        let id = intValue(message["id"]) ?? 0
        guard str(message["jsonrpc"]) == "2.0" else { return errorResponse(id, .couldNotGetRequestData, "Invalid JSON-RPC envelope") }
        guard let method = str(message["method"]) else { return errorResponse(id, .couldNotGetRequestTypeName, "Missing method") }
        do {
            if !files.isEmpty {
                let requestType = (asDict(message["params"])).flatMap { str($0["requestType"]) }
                guard method == "request", requestType == MessagesIPCRoute.commitSend.rawValue else {
                    throw ServiceError(.couldNotGetRequestData, "Attachment file descriptors require a Messages commit request")
                }
            }
            switch method {
            case "ping":
                let params = asDict(message["params"]) ?? [:]
                let clientVersion = str(params["clientApiVersion"]) ?? ""
                guard clientVersion == kApiVersion else {
                    throw ServiceError(.incompatibleClientVersion, SocketJSONRPC.versionMismatchMessage)
                }
                return ["id": id, "jsonrpc": "2.0", "result": ["serverApiVersion": kApiVersion]]
            case "request":
                let params = asDict(message["params"]) ?? [:]
                let clientVersion = str(params["clientApiVersion"]) ?? ""
                guard clientVersion == kApiVersion else {
                    throw ServiceError(.incompatibleClientVersion, SocketJSONRPC.versionMismatchMessage)
                }
                try SocketJSONRPC.validateDeadline(params["deadlineUnixMilliseconds"])
                guard let requestType = str(params["requestType"]) else {
                    throw ServiceError(.couldNotGetRequestTypeName, "Missing requestType")
                }
                guard resolvesRequestType(requestType) else {
                    throw ServiceError(.couldNotResolveRequestType, "Computer Use server error -10003: Could not resolve request type: \(requestType)")
                }
                let result = try RequestRuntime.withRequest(params, cancelled: cancelled, peerPID: peerPID, senderContext: senderContext) {
                    let body: Any?, metadata: Data?
                    do {
                        let data = try wireData ?? JSONSerialization.data(withJSONObject: message)
                        body = try XPCAppUsageBody.decodeSocket(data, for: DirectRequestType(rawValue: requestType))
                            ?? DelegatedRequestBody.decode(data, requestType: requestType, socket: true)
                        metadata = try XPCAppUsageBody.socketMetadata(data)
                    } catch {
                        throw SocketJSONRPC.Failure(code: -32602, message: "Invalid params")
                    }
                    return try ComputerUseTelemetryContext.withAgentTurnMetadata(metadata) {
                        try handleRequest(params, files: files, decodedSocketBody: body)
                    }
                }
                return ["id": id, "jsonrpc": "2.0", "result": try SocketResponseBody.normalize(result, for: requestType)]
            default:
                return errorResponse(id, .unhandledEvent, "Unknown method '\(method)'")
            }
        } catch let serialization as SocketResponseSerializationFailure {
            serializationFailed(serialization)
            return [:]
        } catch let socket as SocketJSONRPC.Failure {
            var response = socket.response
            response["id"] = id
            return response
        } catch let service as ServiceError {
            return errorResponse(id, service.code, service.message)
        } catch let audio as AudioRecorder.Failure {
            let service = audio.socketError
            return errorResponse(id, service.code, service.message)
        } catch {
            return errorResponse(id, .unknownError, "Computer Use server error -10005: \(String(describing: error))")
        }
    }

    private static func handleRequest(_ params: JSON, files: [FileHandle] = [],
                                      nativeActionAppSnapshot: Bool = false,
                                      decodedSocketBody: Any? = nil,
                                      decodeXPCBody: (() throws -> Any)? = nil) throws -> Any? {
        let clientVersion = str(params["clientApiVersion"]) ?? ""
        guard clientVersion == kApiVersion else {
            throw ServiceError(.incompatibleClientVersion, "Incompatible client API version '\(clientVersion)'")
        }
        guard let requestType = str(params["requestType"]) else {
            throw ServiceError(.couldNotGetRequestTypeName, "Missing requestType")
        }
        let preparation = RequestPreparation(requestType: requestType)
        // The app-usage body is decoded before request preparation.
        // Other XPC bodies remain lazy, including the early turn check for lists.
        let earlyBody = preparation.decodesBeforePreparation
            ? try decodeXPCBody?() ?? decodedSocketBody ?? params["request"] : nil
        let activity = requestActivity.begin(preparation)
        defer { activity?.cancel() }
        let preparedTurn = preparation.preparesAgentTurn ? try prepareAgentTurn() : nil
        let body = try earlyBody ?? decodeXPCBody?() ?? decodedSocketBody ?? params["request"]
        if resetsInactivity(for: requestType) {
            Task { @MainActor in idleTimer?.reset() }
        }
        let request = asDict(body) ?? [:]
        let app = str(request["app"]) ?? ""

        switch requestType {
        case DirectRequestType.listApps.rawValue:
            return try AppLifecycle.listApps()
        case DirectRequestType.appPolicy.rawValue:
            return try ComputerUsePolicyIPC.perform(app)
        case DirectRequestType.appStart.rawValue:
            return try AppLifecycle.start(app, native: true)
        case DirectRequestType.appStop.rawValue:
            return try AppLifecycle.stop(app)
        case DirectRequestType.appModify.rawValue:
            guard let modification = asDict(request["modification"]) else { throw ServiceError(.couldNotGetRequestData, "Missing modification") }
            return try AppLifecycle.modify(app, modification: modification, native: true)
        case DirectRequestType.frontmostWindow.rawValue:
            return try AppLifecycle.frontmostWindow()
        case DirectRequestType.appGetAppSnapshot.rawValue:
            return try appSnapshot(app: app, request: request, native: true, pipTurn: preparedTurn)
        case DirectRequestType.appStartCapture.rawValue:
            return try NativeAppCapture.start(request, native: true)
        case DirectRequestType.appNextCaptureUpdate.rawValue:
            return try NativeAppCapture.shared.next(request)
        case DirectRequestType.appPerformAction.rawValue:
            guard let action = asDict(request["action"]) else {
                throw ServiceError(.couldNotGetRequestData, "Missing action")
            }
            let turn = preparedTurn
            return try Actions.perform(app: app, action: action, captureResult: nativeActionAppSnapshot, native: true) { target, snapshot in
                if let snapshot { observePIPWindow(snapshot, turn: turn) }
                return actionResponse(app: target, text: snapshot?.text, screenshotPath: snapshot?.screenshotPath,
                                      native: true)
            }
        case DirectRequestType.startAudioRecording.rawValue:
            let start: AudioRecorder.StartRequest
            do {
                let data = try JSONSerialization.data(withJSONObject: body ?? NSNull(), options: [.fragmentsAllowed])
                start = try JSONDecoder().decode(AudioRecorder.StartRequest.self, from: data)
            } catch {
                if decodeXPCBody != nil { throw error }
                throw ServiceError(.couldNotGetRequestData, "Could not decode \(requestType)")
            }
            let owner = audioOwner
            try RequestRuntime.withCheckpoint({ try requireActiveAgentTurn(owner.turnID) }) {
                try AudioRecorder.shared.start(start, owner: owner)
            }
            return JSON()
        case DirectRequestType.stopAudioRecording.rawValue:
            let url = try AudioRecorder.shared.stop(owner: audioOwner)
            return ["url": url.absoluteString]
        case DirectRequestType.agentTurnEnded.rawValue:
            guard let request = body else {
                throw ServiceError(.couldNotGetRequestData, "Missing request")
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: request, options: [.fragmentsAllowed])
                let ended = try JSONDecoder().decode(AgentTurnEndedRequest.self, from: data)
                agentTurns.recordEnd(ended.turnID)
                AudioRecorder.shared.discardEndedTurn(threadID: ended.threadID, turnID: ended.turnID)
                DispatchQueue.main.async { pipController?.end(threadID: ended.threadID) }
            } catch {
                if decodeXPCBody != nil { throw error }
                throw ServiceError(.couldNotGetRequestData, "Could not decode \(requestType)")
            }
            return JSON()
        case DirectRequestType.statusItemMenuState.rawValue:
            guard body != nil else {
                throw ServiceError(.couldNotGetRequestData, "Missing request")
            }
            return try TimelineIPC.statusMenu()
        case MessagesIPCRoute.readImage.rawValue:
            guard let request = body else {
                throw ServiceError(.couldNotGetRequestData, "Missing request")
            }
            return try MessagesIPC.readImage(request: request)
        case MessagesIPCRoute.readMessages.rawValue:
            guard let request = body else {
                throw ServiceError(.couldNotGetRequestData, "Missing request")
            }
            return try MessagesIPC.readMessages(request: request)
        case MessagesIPCRoute.findChats.rawValue, MessagesIPCRoute.searchChats.rawValue:
            guard let request = body else {
                throw ServiceError(.couldNotGetRequestData, "Missing request")
            }
            return try requestType == MessagesIPCRoute.findChats.rawValue
                ? MessagesIPC.findChats(request: request) : MessagesIPC.searchChats(request: request)
        case MessagesIPCRoute.searchMessages.rawValue:
            guard let request = body else {
                throw ServiceError(.couldNotGetRequestData, "Missing request")
            }
            return try MessagesIPC.searchMessages(request: request)
        case MessagesIPCRoute.countActivity.rawValue:
            guard let request = body else {
                throw ServiceError(.couldNotGetRequestData, "Missing request")
            }
            return try MessagesIPC.countActivity(request: request)
        case MessagesIPCRoute.prepareSend.rawValue:
            guard let request = body else {
                throw ServiceError(.couldNotGetRequestData, "Missing request")
            }
            return try MessagesIPC.prepareSend(request: request)
        case MessagesIPCRoute.commitSend.rawValue:
            guard let request = body else {
                throw ServiceError(.couldNotGetRequestData, "Missing request")
            }
            return try MessagesIPC.commitSend(request: request, files: files)
        case DirectRequestType.eventStreamStart.rawValue, DirectRequestType.eventStreamStatus.rawValue, DirectRequestType.eventStreamStop.rawValue:
            guard let request = body else { throw ServiceError(.couldNotGetRequestData, "Missing request") }
            return try EventStreamIPC.perform(requestType: requestType, request: request,
                                              preserveDecodingError: decodeXPCBody != nil)
        default:
            if let route = CalendarOperation.Route(rawValue: requestType) {
                guard let request = body else {
                    throw ServiceError(.couldNotGetRequestData, "Missing request")
                }
                guard #available(macOS 14, *) else { throw CalendarPermissionGate.denied }
                return try CalendarIPC.perform(route: route, request: request)
            }
            if let route = TimelineOperation.Route(rawValue: requestType) {
                guard let request = body else {
                    throw ServiceError(.couldNotGetRequestData, "Missing request")
                }
                return try TimelineIPC.perform(route: route, request: request)
            }
            throw ServiceError(.couldNotResolveRequestType, "Unsupported request type '\(requestType)'")
        }
    }

    private static var audioOwner: AudioRecorder.Owner {
        let metadata = ComputerUseTelemetryContext.snapshot()
        return .init(sessionID: metadata.agentSessionID,
                     senderPID: RequestRuntime.peerPID ?? ProcessInfo.processInfo.processIdentifier,
                     turnID: metadata.agentTurnID)
    }

    static func actionResponse(app: IPCApp, text: String?, screenshotPath: String?, native: Bool) -> JSON {
        var response: JSON = ["app": app.json]
        if let text {
            var shot: JSON = ["text": text]
            if let screenshotPath {
                let file = URL(fileURLWithPath: screenshotPath)
                let mimeType = file.pathExtension == "png" ? "image/png" : "image/jpeg"
                shot["screenshot"] = ["url": file.absoluteString, "mimeType": mimeType]
            }
            response["appSnapshot"] = shot
        }
        return response
    }

    static func appSnapshot(app: String, request: JSON, native: Bool, pipTurn: RemoteHostedPIPController.Turn?) throws -> JSON {
        let disableDiff = boolValue(request["disableDiff"]) ?? false
        let canonical = AppResolver.resolve(app)?.bundleIdentifier ?? app
        return try RequestRuntime.serialized(app: canonical) {
            let snapshot = try AXCapture.capture(app: app, disableDiff: disableDiff, native: native)
            observePIPWindow(snapshot, turn: pipTurn)
            return appSnapshotResult(snapshot, native: native)
        }
    }

    static func appSnapshotResult(_ snapshot: AXSnapshot, native: Bool) -> JSON {
        var state = actionResponse(app: snapshot.appReference, text: snapshot.text, screenshotPath: snapshot.screenshotPath, native: true)
        state["appSpecificInstructions"] = AppSpecificInstructions.resolve(for: snapshot.appReference)
        return state
    }

    static func errorResponse(_ id: Int, _ code: CUErrorCode, _ message: String) -> JSON {
        ["id": id, "jsonrpc": "2.0", "error": ["code": code.rawValue, "message": message]]
    }

    static func handleXPC(peer: PeerAuditCredentials, type: String, request: Data?, metadata: Data?,
                          files: [FileHandle], returnActionAppSnapshot: Bool = true,
                          senderContext: SenderRequestContext? = nil,
                          cancelled: @escaping () -> Bool) throws -> Data {
        guard senderContext?.foregroundOnly != true else {
            throw ServiceError(.senderProcessNotAuthenticated, "Sender process is not authenticated")
        }
        guard resolvesRequestType(type) else {
            throw ServiceError(.couldNotResolveRequestType, "Could not resolve request type: \(type)")
        }
        guard (request?.count ?? 0) <= kMaxFrameBytes else {
            throw ServiceError(.couldNotGetRequestData, "Could not decode \(type)")
        }
        let params: JSON = ["clientApiVersion": kApiVersion, "requestType": type]
        let delivery = ResponseDelivery()
        let data = try ResponseDelivery.withCurrent(delivery) {
            try ComputerUseTelemetryContext.withAgentTurnMetadata(metadata) {
                try RequestRuntime.withRequest(params, cancelled: cancelled, peerPID: peer.pid,
                                              senderContext: senderContext ?? SenderRequestContext.resolveNative(peer.pid)) {
                    let result = try handleRequest(params, files: files, nativeActionAppSnapshot: returnActionAppSnapshot) {
                        try DelegatedRequestBody.decode(request, requestType: type, socket: false)
                            ?? XPCAppUsageBody.decode(request, for: DirectRequestType(rawValue: type))
                    } ?? NSNull()
                    let encoded = try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
                    try RequestRuntime.check()
                    return encoded
                }
            }
        }
        guard !cancelled() else { throw ServiceError(.unknownError, "Request cancelled") }
        delivery.commit()
        return data
    }
}

// MARK: - Unix-socket server

func defaultSocketPath() -> String? {
    ServiceSocketLocation.resolve(arguments: CommandLine.arguments,
        override: ProcessInfo.processInfo.environment["ACUA_SERVICE_NATIVE_PIPE_PATH"],
        container: { EventStreamStorageConfiguration.nativeContainerURL() })?.path(percentEncoded: false)
}

final class Connection: @unchecked Sendable {
    private let fd: Int32
    private var decoder = FrameDecoder()
    private let peerPID: Int32?
    private let senderContext: SenderRequestContext?
    private let io: SocketIO

    init(io: SocketIO, credentials: PeerAuditCredentials, senderContext: SenderRequestContext?) {
        self.io = io
        fd = io.fd
        peerPID = credentials.pid
        self.senderContext = senderContext
    }

    func serve() {
        defer { io.closeOwnedDescriptor() }
        while !io.isCancelled {
            let end = io.deadline()
            let messages: [Data]
            var files = [FileHandle]()
            do {
                guard let header = try io.readExactly(4, until: end, files: &files) else { return }
                let size = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
                let empty = decoder.append(header)
                if decoder.failure != nil || size == 0 { messages = empty }
                else {
                    guard let body = try io.readExactly(size, until: end, files: &files) else {
                        throw SocketIOError.disconnected
                    }
                    messages = decoder.append(body)
                }
            } catch SocketIOError.timedOut { return }
              catch is CancellationError { return }
              catch {
                // 0x10017D378 sends one null-ID internal error on a failed
                // frame read, then closes. Clean EOF before a header and
                // cancellation/deadline expiry do not send that response.
                let failure = SocketJSONRPC.Failure(code: -32603, message: "Internal error")
                writeAll(encodeFrame(jsonString(failure.response)))
                return
            }
            for data in messages {
                let request: SocketJSONRPC.Request
                do { request = try SocketJSONRPC.decode(data) }
                catch let failure as SocketJSONRPC.Failure {
                    guard writeAll(encodeFrame(jsonString(failure.response))) else { return }
                    continue
                } catch { return }
                switch request.kind {
                case .close:
                    writeAll(encodeFrame(jsonString(request.closeResponse)))
                    return
                case .unknown:
                    let failure = SocketJSONRPC.Failure(id: request.id, code: -32601, message: "Method not found")
                    guard writeAll(encodeFrame(jsonString(failure.response))) else { return }
                    continue
                case .ping, .request: break
                }
                let delivery = ResponseDelivery()
                var serializationFailure: Error?
                var response = ResponseDelivery.withCurrent(delivery) {
                    Dispatch.handle(request.message, cancelled: { [self] in
                        var status = pollfd(fd: fd, events: Int16(POLLHUP | POLLERR), revents: 0)
                        return io.isCancelled || poll(&status, 1, 0) > 0 && (status.revents & Int16(POLLHUP | POLLERR | POLLNVAL)) != 0
                    }, peerPID: peerPID, senderContext: senderContext, files: files, wireData: data,
                       serializationFailed: { serializationFailure = $0 })
                }
                guard serializationFailure == nil else { delivery.abandon(); return }
                response["id"] = request.id.json
                guard JSONSerialization.isValidJSONObject(response) else { delivery.abandon(); return }
                if response["error"] != nil { delivery.abandon() }
                let frame = encodeFrame(jsonString(response))
                if frame.count > kMaxFrameBytes + 4 {
                    delivery.abandon()
                    let failure = SocketJSONRPC.Failure(id: request.id, code: -32002,
                                                       message: "Response exceeds maximum frame size")
                    guard writeAll(encodeFrame(jsonString(failure.response))) else { return }
                    continue
                }
                guard writeAll(frame) else { delivery.abandon(); return }
                delivery.commit()
            }
            if decoder.failure != nil {
                let error = SocketJSONRPC.Failure(code: -32603, message: "Internal error")
                writeAll(encodeFrame(jsonString(error.response)))
                return
            }
        }
    }

    @discardableResult private func writeAll(_ data: Data) -> Bool {
        guard data.count <= kMaxFrameBytes + 4 else { return false }
        do { try io.writeAll(data); return true } catch { return false }
    }
}


// MARK: - Self-test (pure logic; no TCC required)

func runSelfTest() -> Int32 {
    // Self-tests exercise dispatch with owned providers, without declaring
    // real user activity or changing the display's idle-sleep behavior.
    let nativeActivity = Dispatch.requestActivity
    Dispatch.requestActivity = RequestActivity(provider: .init(create: { _, _ in -1 }, release: { _ in 0 }))
    defer { Dispatch.requestActivity = nativeActivity }
    var failures = 0
    func expect(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — " + detail)")
        if !ok { failures += 1 }
    }

    // Frame codec: two messages arriving in split chunks.
    let f1 = encodeFrame("{\"a\":1}")
    let f2 = encodeFrame("{\"b\":2}")
    var decoder = FrameDecoder()
    let part1 = decoder.append(f1.prefix(3))
    let part2 = decoder.append(f1.dropFirst(3) + f2)
    expect("frame decoder buffers partial header", part1.isEmpty)
    expect("frame decoder yields both messages", part2 == [Data("{\"a\":1}".utf8), Data("{\"b\":2}".utf8)])

    // Frame header is little-endian length.
    let body = "hello"
    let frame = encodeFrame(body)
    let length = frame.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self) }
    expect("frame length is LE uint32", UInt32(littleEndian: length) == UInt32(body.utf8.count))

    // JSON round trip.
    let payload: JSON = ["id": 7, "jsonrpc": "2.0", "result": ["serverApiVersion": kApiVersion]]
    let round = jsonObject(Data(jsonString(payload).utf8))
    expect("json round trip", asDict(round)?["id"] as? Int == 7)

    // Key code parsing.
    expect("key Return", KeyCodes.code(for: "Return") == 36)
    expect("key a", KeyCodes.code(for: "a") == 0)
    expect("key F5", KeyCodes.code(for: "f5") == 96)
    expect("key unknown", KeyCodes.code(for: "nope") == nil)

    // Policy + app resolution against the live workspace.
    let finder = (try? Policy.decision(for: "Finder")) ?? [:]
    expect("policy allows Finder", str(finder["decision"]) == "allowed", str(finder["decision"]) ?? "")
    do {
        _ = try Policy.decision(for: "definitely.not.running.xyz")
        expect("policy reports invalid app for an unknown target", false)
    } catch let error as ServiceError {
        expect("policy reports invalid app for an unknown target", error.code == .invalidApp)
    } catch { expect("policy reports invalid app for an unknown target", false) }

    // Dispatch: ping handshake.
    let ping = Dispatch.handle(["id": 1, "jsonrpc": "2.0", "method": "ping", "params": ["clientApiVersion": kApiVersion]])
    expect("ping ok", asDict(ping["result"])?["serverApiVersion"] as? String == kApiVersion)

    let badPing = Dispatch.handle(["id": 2, "jsonrpc": "2.0", "method": "ping", "params": ["clientApiVersion": "AcuaComputerUseIPC-1"]])
    expect("ping rejects wrong version", asDict(badPing["error"])?["code"] as? Int == CUErrorCode.incompatibleClientVersion.rawValue)

    // Dispatch: list apps.
    let list = Dispatch.handle(["id": 3, "jsonrpc": "2.0", "method": "request", "params": [
        "clientApiVersion": kApiVersion, "requestType": "ComputerUseIPCListAppsRequest", "request": [:],
    ]])
    let apps = array(list["result"]) ?? []
    expect("list apps returns array", !apps.isEmpty, "\(apps.count) apps")

    // Dispatch: unknown request type.
    let unknown = Dispatch.handle(["id": 4, "jsonrpc": "2.0", "method": "request", "params": [
        "clientApiVersion": kApiVersion, "requestType": "Nope", "request": [:],
    ]])
    expect("unknown request type -> -10003", asDict(unknown["error"])?["code"] as? Int == CUErrorCode.couldNotResolveRequestType.rawValue)

    func turnEnded(_ body: Any?) -> JSON {
        var params: JSON = ["clientApiVersion": kApiVersion, "requestType": "ComputerUseIPCTurnEndedRequest"]
        params["request"] = body
        return Dispatch.handle(["id": 5, "jsonrpc": "2.0", "method": "request", "params": params])
    }
    expect("turn ended returns an empty response", asDict(turnEnded(["threadID": "thread", "turnID": "turn"])["result"])?.isEmpty == true)
    expect("turn ended accepts a missing turn ID", asDict(turnEnded(["threadID": ""])["result"])?.isEmpty == true)
    expect("turn ended accepts a null turn ID", asDict(turnEnded(["threadID": "thread", "turnID": NSNull()])["result"])?.isEmpty == true)
    for body: Any? in [nil, NSNull(), [:] as JSON, ["threadID": 1], ["threadID": "thread", "turnID": false]] {
        let response = turnEnded(body)
        expect("turn ended rejects an invalid body",
               asDict(response["error"])?["code"] as? Int == -32602 &&
               (asDict(response["error"])?["message"] as? String) == "Invalid params")
    }

    let xpcPeer = PeerAuditCredentials(pid: getpid(), uid: geteuid(), auditToken: Data())
    let xpcTurnType = DirectRequestType.agentTurnEnded.rawValue
    func xpcRequest(_ type: String, _ body: String?, files: [FileHandle] = [],
                    metadata: Data? = nil) -> Result<Data, NSError> {
        do {
            return .success(try Dispatch.handleXPC(peer: xpcPeer, type: type, request: body.map { Data($0.utf8) },
                                                   metadata: metadata, files: files, cancelled: { false }))
        } catch {
            return .failure(ComputerUseXPC.requestError(error))
        }
    }
    func xpcError(_ type: String, _ body: String?) -> NSError? {
        guard case .failure(let error) = xpcRequest(type, body) else { return nil }
        return error
    }
    let xpcUnknown = xpcError("Nope", "{")
    expect("XPC resolves the request name before decoding malformed bytes",
           xpcUnknown?.code == -10003 && xpcUnknown?.localizedDescription == "Could not resolve request type: Nope")
    for body: String? in ["{", nil] {
        let error = xpcError(xpcTurnType, body)
        expect("XPC reports native JSON decoding failure for malformed or missing data",
               error?.code == -10005 && error?.localizedDescription.contains("dataCorrupted") == true)
    }
    for route in [DirectRequestType.appStop, .appPolicy] {
        let missing = xpcError(route.rawValue, "{}")
        let wrongType = xpcError(route.rawValue, #"{"app":false}"#)
        expect("XPC \(route) validates the required app identifier",
               missing?.code == -10005 && missing?.localizedDescription.contains("keyNotFound") == true &&
               wrongType?.code == -10005 && wrongType?.localizedDescription.contains("typeMismatch") == true)
    }
    let xpcModifyType = DirectRequestType.appModify.rawValue
    let unknownModification = xpcError(xpcModifyType, #"{"app":"org.cua.selftest.nonexistent.5fb9c03d","modification":{"future":{}}}"#)
    expect("XPC app modify rejects an unknown operation during decoding",
           unknownModification?.code == -10005 && unknownModification?.localizedDescription.contains("typeMismatch") == true)
    let extendedModification = xpcError(xpcModifyType, #"{"app":"org.cua.selftest.nonexistent.5fb9c03d","modification":{"activate":{"future":true},"future":{}}}"#)
    expect("XPC app modify ignores unknown fields in a valid operation",
           extendedModification?.code == CUErrorCode.runningApplicationNotFound.rawValue)
    let xpcMissingField = xpcError(xpcTurnType, "{}")
    expect("XPC preserves the typed turn-ended decoding error",
           xpcMissingField?.code == -10005 && xpcMissingField?.localizedDescription.contains("threadID") == true)
    let xpcWithDescriptor = try? xpcRequest(xpcTurnType, #"{"threadID":"owned"}"#, files: [.nullDevice]).get()
    expect("XPC ignores unused valid descriptors on turn-ended requests",
           xpcWithDescriptor.flatMap(jsonObject)?.isEmpty == true)

    let eventStop = DirectRequestType.eventStreamStop.rawValue
    let missingReason = xpcError(eventStop, "{}")
    let unknownReason = xpcError(eventStop, #"{"reason":"future"}"#)
    expect("XPC event stream stop preserves reason decoding errors",
           missingReason?.code == -10005 && missingReason?.localizedDescription.contains("keyNotFound") == true &&
           unknownReason?.code == -10005 && unknownReason?.localizedDescription.contains("dataCorrupted") == true)
    let socketEventStop = Dispatch.handle(["id": 7, "jsonrpc": "2.0", "method": "request", "params": [
        "clientApiVersion": kApiVersion, "requestType": eventStop, "request": JSON(),
    ]])
    expect("socket event stream stop keeps the JSON-RPC invalid-params envelope",
           asDict(socketEventStop["error"])?["code"] as? Int == -32602 &&
           (asDict(socketEventStop["error"])?["message"] as? String) == "Invalid params")

    expect("inactivity refresh follows authenticated request selection",
           Dispatch.resetsInactivity(for: DirectRequestType.appPerformAction.rawValue) &&
           Dispatch.resetsInactivity(for: DirectRequestType.eventStreamStatus.rawValue) &&
           !Dispatch.resetsInactivity(for: DirectRequestType.appPolicy.rawValue) &&
           !Dispatch.resetsInactivity(for: DirectRequestType.agentTurnEnded.rawValue) &&
           !Dispatch.resetsInactivity(for: "ping") &&
           !Dispatch.resetsInactivity(for: "unknown"))
    let tracker = ComputerUseSessionTracker()
    let now = Date(timeIntervalSinceReferenceDate: 10_000)
    tracker.recordEnd(nil, now: now)
    tracker.recordEnd("", now: now)
    expect("empty turn identifiers are not recorded", !tracker.hasEnded("", now: now))
    tracker.recordEnd("expired", now: now.addingTimeInterval(-300))
    tracker.recordEnd("current", now: now)
    expect("ended turn is tracked for exactly five minutes",
           tracker.hasEnded("current", now: now.addingTimeInterval(299.999)) &&
           !tracker.hasEnded("current", now: now.addingTimeInterval(300)) &&
           !tracker.hasEnded("expired", now: now))
    tracker.recordEnd("current", now: now.addingTimeInterval(100))
    expect("repeating the end notification renews the expiry",
           tracker.hasEnded("current", now: now.addingTimeInterval(300)))

    let metadata: JSON = ["turn_id": "turn", "session_id": "another-thread"]
    let routes: [DirectRequestType] = [
        .appStart, .appGetAppSnapshot, .appPerformAction, .listApps, .startAudioRecording, .stopAudioRecording,
    ]
    let action: JSON = ["app": "owned-fixture", "action": ["type": ["_0": "fixture"]]]
    func agentRequest(_ type: DirectRequestType, _ metadata: JSON, body: JSON = [:]) -> JSON {
        Dispatch.handle(["id": 6, "jsonrpc": "2.0", "method": "request", "params": [
            "clientApiVersion": kApiVersion, "requestType": type.rawValue, "request": body,
            "agentTurnMetadata": metadata,
        ]])
    }
    let message = "Computer Use is unavailable because the current turn ended. It will work again after the next user message."
    for route in routes {
        let error = asDict(agentRequest(route, metadata, body: action)["error"])
        expect("\(route) rejects an ended turn across sessions",
               error?["code"] as? Int == -10021 && error?["message"] as? String == message)
    }
    expect("ended turn does not block unrelated routes",
           asDict(agentRequest(.appPolicy, metadata, body: ["app": "test.acua.missing.selftest"])["error"])?["code"] as? Int == -10010)
    expect("subsequent turns enter the normal action handler",
           asDict(agentRequest(.appPerformAction, ["turn_id": "next"], body: action)["error"])?["code"] as? Int == -10007)
    let xpcActionType = DirectRequestType.appPerformAction.rawValue
    let endedMetadata = Data(#"{"turn_id":"turn"}"#.utf8)
    if case .failure(let error) = xpcRequest(xpcActionType, jsonString(action), metadata: endedMetadata) {
        expect("XPC rejects a decoded action from an ended turn",
               error.code == -10021 && error.domain == "ComputerUseIPCXPC" && error.localizedDescription == message)
    } else {
        expect("XPC rejects a decoded action from an ended turn", false)
    }
    for malformed in ["{", #"{"app":"owned-fixture","action":{"type":{}}}"#] {
        if case .failure(let error) = xpcRequest(xpcActionType, malformed, metadata: endedMetadata) {
            expect("XPC action decoding precedes the turn check", error.code == -10005)
        } else {
            expect("XPC action decoding precedes the turn check", false)
        }
    }
    if case .failure(let error) = xpcRequest(DirectRequestType.listApps.rawValue, "{", metadata: endedMetadata) {
        expect("XPC app listing checks the ended turn before decoding", error.code == -10021)
    } else {
        expect("XPC app listing checks the ended turn before decoding", false)
    }

    do {
        let inertActivity = Dispatch.requestActivity
        defer { Dispatch.requestActivity = inertActivity }
        var activityEvents = [String]()
        Dispatch.requestActivity = RequestActivity(provider: .init(create: { kind, id in
            id = kind == .remoteUserActivity ? 71 : 72
            activityEvents.append("create:\(id)")
            return 0
        }, release: { id in activityEvents.append("release:\(id)"); return 0 }))
        let completeActivity = ["create:71", "create:72", "release:72", "release:71"]
        for route in routes {
            activityEvents.removeAll()
            _ = agentRequest(route, metadata, body: action)
            expect("\(route) releases both activity assertions on turn rejection", activityEvents == completeActivity)
        }
        activityEvents.removeAll()
        _ = xpcRequest(xpcActionType, "{", metadata: endedMetadata)
        expect("XPC app-usage decode failure precedes activity acquisition", activityEvents.isEmpty)
        _ = xpcRequest(DirectRequestType.listApps.rawValue, "{", metadata: endedMetadata)
        expect("XPC early turn rejection releases request activity", activityEvents == completeActivity)
        activityEvents.removeAll()
        _ = agentRequest(.appPolicy, metadata, body: ["app": "test.acua.missing.selftest"])
        expect("the policy fast path acquires no request activity", activityEvents.isEmpty)
        for type in ["ComputerUseIPCMessagesFindChatsRequest", "ComputerUseIPCCalendarListEventsRequest",
                     "ComputerUseIPCTimelineStatusRequest", DirectRequestType.agentTurnEnded.rawValue] {
            _ = xpcRequest(type, "{")
        }
        expect("exempt requests acquire no activity even when decoding fails", activityEvents.isEmpty)
        _ = xpcRequest(DirectRequestType.appModify.rawValue, "{")
        expect("a non-app-usage decoder failure releases acquired activity", activityEvents == completeActivity)
    }

    do {
        let savedActivity = Dispatch.requestActivity
        defer { Dispatch.requestActivity = savedActivity }
        let observationLock = NSLock()
        var observedContexts = [SenderRequestContext?]()
        Dispatch.requestActivity = RequestActivity(provider: .init(create: { kind, id in
            observationLock.withLock { observedContexts.append(RequestRuntime.senderContext) }
            id = kind == .remoteUserActivity ? 81 : 82
            return 0
        }, release: { _ in 0 }))
        let first = SenderRequestContext(senderPID: 123, responsibleIdentity: .init(bundleID: "owned.first"), ancestorIdentities: [])
        let second = SenderRequestContext(senderPID: 123, responsibleIdentity: .init(bundleID: "owned.second"), ancestorIdentities: [])
        func exerciseConnection(_ context: SenderRequestContext, requests: Int) throws -> Bool {
            var pair: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw SocketIOError.system(errno) }
            let done = DispatchSemaphore(value: 0)
            var started = false
            defer {
                _ = shutdown(pair[1], SHUT_RDWR)
                close(pair[1])
                if started { _ = done.wait(timeout: .now() + 3) }
                else { close(pair[0]) }
            }
            let server = Connection(io: try SocketIO(fd: pair[0], timeout: .seconds(2)),
                credentials: .init(pid: 123, uid: geteuid(), auditToken: Data(repeating: 1, count: 32)),
                senderContext: context)
            let thread = Thread { server.serve(); done.signal() }
            started = true
            thread.start()
            let client = try SocketIO(fd: pair[1], timeout: .seconds(2))
            for id in 0..<requests {
                let message: JSON = ["id": id, "jsonrpc": "2.0", "method": "request", "params": [
                    "clientApiVersion": kApiVersion, "requestType": DirectRequestType.listApps.rawValue, "request": [:],
                ]]
                try client.writeAll(encodeFrame(jsonString(message)))
                let until = client.deadline()
                guard let header = try client.readExactly(4, until: until) else { return false }
                let length = header.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))) }
                guard length <= kMaxFrameBytes, let data = try client.readExactly(length, until: until),
                      let reply = jsonFrameObject(data), reply["result"] != nil else { return false }
            }
            return true
        }
        let firstPassed = try exerciseConnection(first, requests: 2)
        expect("one socket connection keeps its admitted identity across requests",
               firstPassed && observationLock.withLock { observedContexts == [first, first, first, first] })
        let secondPassed = try exerciseConnection(second, requests: 1)
        expect("a new socket connection captures a new identity for the same peer PID",
               secondPassed && observationLock.withLock { observedContexts == [first, first, first, first, second, second] })
    } catch {
        expect("owned socket sender-context lifecycle completes", false, String(describing: error))
    }

    do {
        var restricted = SenderRequestContext(senderPID: xpcPeer.pid, responsibleIdentity: nil, ancestorIdentities: [])
        restricted.foregroundOnly = true
        _ = try Dispatch.handleXPC(peer: xpcPeer, type: "UnresolvableFixture", request: Data("{".utf8),
            metadata: nil, files: [], senderContext: restricted, cancelled: { false })
        expect("restricted XPC context refuses dispatch before type and body decoding", false)
    } catch let error as ServiceError {
        expect("restricted XPC context refuses dispatch before type and body decoding",
               error.code == .senderProcessNotAuthenticated && error.message == "Sender process is not authenticated")
    } catch { expect("restricted XPC context refuses dispatch before type and body decoding", false) }

    let ownedApp = IPCApp(pid: 123, bundleIdentifier: "owned.fixture", appPath: nil)
    let bareAction = Dispatch.actionResponse(app: ownedApp, text: nil, screenshotPath: nil, native: true)
    expect("action response omits an unavailable appSnapshot", bareAction["appSnapshot"] == nil)
    let textAction = Dispatch.actionResponse(app: ownedApp, text: "AXButton", screenshotPath: nil, native: true)
    let textShot = asDict(textAction["appSnapshot"])
    expect("action response preserves text when the screenshot is unavailable",
           textShot?["text"] as? String == "AXButton" && textShot?["screenshot"] == nil)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("cua action \(UUID().uuidString).jpg")
    let nativeAction = Dispatch.actionResponse(app: ownedApp, text: "", screenshotPath: file.path, native: true)
    let screenshot = asDict(asDict(nativeAction["appSnapshot"])?["screenshot"])
    expect("native action screenshot uses an encoded file URL and MIME type",
           screenshot?["url"] as? String == file.absoluteString && screenshot?["mimeType"] as? String == "image/jpeg")
    do {
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let socketAction = Dispatch.actionResponse(app: ownedApp, text: "", screenshotPath: file.path, native: false)
        let image = asDict(asDict(socketAction["appSnapshot"])?["screenshot"])
        expect("socket action screenshot keeps the native file URL and MIME type",
               image?["url"] as? String == file.absoluteString && image?["mimeType"] as? String == "image/jpeg")
    } catch {
        expect("socket action screenshot keeps the native file URL and MIME type", false, String(describing: error))
    }

    do {
        let index = AXIndex()
        let manager = FileManager.default
        try manager.createDirectory(at: Capture.temporaryDirectory, withIntermediateDirectories: true)
        var paths: [String] = []
        defer { for path in paths { Capture.removeTemporaryImage(path) } }
        func snapshot(_ process: String, app: IPCApp = ownedApp) throws -> AXSnapshot {
            let path = Capture.temporaryDirectory.appendingPathComponent("app-snapshot-\(UUID().uuidString).jpg")
            paths.append(path.path)
            try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: path)
            let revision = TreeRevision<AXReference>(session: process, number: 0, sections: [], entries: [], changes: [],
                                                     fullText: "", text: "", isDiff: false, truncated: false)
            return AXSnapshot(app: "Fixture", bundleIdentifier: app.bundleIdentifier, text: "", windowOrigin: .zero,
                              windowSize: .zero, windowTitle: "", screenshotPath: path.path, geometry: nil, windowElement: nil,
                              processKey: process, revision: revision, appReference: app)
        }
        func exists(_ snapshot: AXSnapshot) -> Bool {
            snapshot.screenshotPath.map { manager.fileExists(atPath: $0) } ?? false
        }
        let first = try snapshot("123:first")
        let inline = try snapshot(first.processKey)
        let second = try snapshot(first.processKey)
        try index.publish(first, retainImage: true) { true }
        try index.publish(inline, retainImage: false) { true }
        try index.publish(second, retainImage: true) { true }
        expect("native JPEGs survive later snapshots while obsolete inline files are removed",
               exists(first) && exists(second) && !exists(inline))
        index.applicationTerminated(processKey: "123:other-generation")
        expect("a stale process notification leaves the current files in place", exists(first) && exists(second))
        let replacement = try snapshot("123:replacement")
        try index.publish(replacement, retainImage: true) { true }
        expect("replacing an app process releases all files owned by the old process",
               !exists(first) && !exists(second) && exists(replacement))
        let sibling = try snapshot("456:sibling", app: IPCApp(pid: 456, bundleIdentifier: "owned.sibling", appPath: nil))
        try index.publish(sibling, retainImage: true) { true }
        index.applicationTerminated(processKey: replacement.processKey)
        expect("termination releases only the captured files of the exited process",
               !exists(replacement) && exists(sibling) && index.snapshot(for: ownedApp.bundleIdentifier) == nil)
        index.invalidate(sibling.bundleIdentifier)
        expect("deactivation releases native files and the latest snapshot", !exists(sibling) && index.snapshot(for: sibling.bundleIdentifier) == nil)
        let final = try snapshot("789:final")
        try index.publish(final, retainImage: true) { true }
        index.shutdown()
        expect("service shutdown releases retained files", !exists(final))
        let admitted = (try? index.publish(final, retainImage: true) { true }) != nil
        expect("a late capture cannot republish files after shutdown", !admitted)
    } catch {
        expect("appSnapshot lifetime fixture completes", false, String(describing: error))
    }

    do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-instructions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func resource(_ name: String, _ data: Data) throws -> URL {
            let file = directory.appendingPathComponent(name)
            try data.write(to: file)
            return file
        }
        let name = try resource("Music.MD", Data("name\n".utf8))
        let alias = try resource("AppleMusic.md", Data("alias".utf8))
        let identifier = try resource("com.apple.Music.md", Data("identifier".utf8))
        let other = try resource("Ignored.txt", Data("ignored".utf8))
        let resources = AppSpecificInstructions.index([name, alias, identifier, other])
        expect("instruction files use exact stems and case-insensitive Markdown extensions",
               Set(resources.keys) == ["Music", "AppleMusic", "com.apple.Music"])
        func instructions(_ id: String, _ name: String? = nil, _ schemes: [String] = []) -> String? {
            AppSpecificInstructions.resolve(bundleIdentifier: id, bundleName: name,
                urlTypes: [["CFBundleURLSchemes": schemes]], resources: resources)
        }
        expect("Music alias takes priority over its name and bundle identifier",
               instructions("com.apple.Music", "Music") == "alias")
        expect("bundle name lookup preserves exact file content",
               instructions("other.music", "Music") == "name\n" && instructions("other.music", "music") == nil)
        try Data().write(to: alias)
        expect("an empty alias falls through to the bundle name", instructions("com.apple.Music", "Music") == "name\n")
        try Data([0xFF]).write(to: name)
        expect("an undecodable resource falls through to the exact bundle identifier",
               instructions("com.apple.Music", "Music") == "identifier")
        expect("browser guidance precedes app instructions with two newlines",
               instructions("com.apple.Music", nil, ["http"]) == AppSpecificInstructions.browser + "\n\nidentifier")
        expect("browser guidance can stand alone and needs the exact http scheme",
               instructions("missing", nil, ["http"]) == AppSpecificInstructions.browser &&
                   instructions("missing", nil, ["https", "HTTP"]) == nil)

        let app = IPCApp(pid: 123, bundleIdentifier: "com.apple.Music", appPath: nil)
        let revision = TreeRevision<AXReference>(session: "owned", number: 0, sections: [], entries: [], changes: [],
                                                 fullText: "", text: "", isDiff: false, truncated: false)
        let snapshot = AXSnapshot(app: "Music", bundleIdentifier: app.bundleIdentifier, text: "AXWindow", windowOrigin: .zero,
                                  windowSize: .zero, windowTitle: "", screenshotPath: nil, geometry: nil, windowElement: nil,
                                  processKey: "owned", revision: revision, appReference: app)
        let native = Dispatch.appSnapshotResult(snapshot, native: true)
        let socket = Dispatch.appSnapshotResult(snapshot, native: false)
        let action = Dispatch.actionResponse(app: app, text: snapshot.text, screenshotPath: nil, native: true)
        let packaged = native["appSpecificInstructions"] as? String
        expect("native and socket state responses load shipped instructions even without a screenshot",
               packaged?.utf8.count == 1260 && socket["appSpecificInstructions"] as? String == packaged &&
                   asDict(native["appSnapshot"])?["text"] as? String == "AXWindow")
        expect("post-action response omits app-specific instructions", action["appSpecificInstructions"] == nil)
    } catch {
        expect("instruction fixture completes", false, String(describing: error))
    }

    do {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("cua-native-images-\(UUID())", isDirectory: true)
        defer { try? manager.removeItem(at: directory) }
        guard let context = CGContext(data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ServiceError(.unknownError, "Could not create the screenshot fixture bitmap")
        }
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        guard let image = context.makeImage() else { throw ServiceError(.unknownError, "Could not create the screenshot fixture image") }
        let encoding = NativeAppSnapshotImage.encoding(useJPEG: true, quality: 0.8)
        let png = NativeAppSnapshotImage.encoding(useJPEG: false, quality: 0.8)
        let invalidQualities = [0.0, -0.1, 1.01, .infinity, .nan]
        expect("native codec settings select JPEG, PNG and default-quality fallback",
               encoding.type.identifier == "public.jpeg" && encoding.properties != nil && png.type.identifier == "public.png" &&
                   invalidQualities.allSatisfy { NativeAppSnapshotImage.encoding(useJPEG: true, quality: $0).properties == nil })
        let nativeSizing = NativeAppSnapshotImage.Settings(legacySizing: false, normalizeToPoints: true, encoding: encoding)
        let legacy = NativeAppSnapshotImage.Settings(legacySizing: true, normalizeToPoints: false, encoding: encoding)
        let normalized = NativeAppSnapshotImage.Settings(legacySizing: true, normalizeToPoints: true, encoding: encoding)
        expect("native sizing only normalizes to points in legacy mode above one backing scale",
               nativeSizing.sizing(backingScale: 2) == .native && legacy.sizing(backingScale: 2) == .legacy &&
                   normalized.sizing(backingScale: 2) == .points && normalized.sizing(backingScale: 1) == .legacy)
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try NativeAppSnapshotImage.write(image, appName: "App/Name", directory: directory, date: time, encoding: encoding)
        defer { Capture.removeTemporaryImage(first.path) }
        let source = CGImageSourceCreateWithURL(first as CFURL, nil)
        let decoded = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        expect("native writer creates a readable JPEG with an app and date filename",
               first.lastPathComponent.hasPrefix("App:Name ") && first.lastPathComponent.contains(" at ") &&
                   first.pathExtension == "jpeg" && decoded?.width == 32 && decoded?.height == 24)
        DispatchQueue.concurrentPerform(iterations: 6) { _ in
            _ = try? NativeAppSnapshotImage.write(image, appName: "App/Name", directory: directory, date: time, encoding: encoding)
        }
        let colliding = (1...6).map { directory.appendingPathComponent("\($0)/\(first.lastPathComponent)") }
        defer { for file in colliding { Capture.removeTemporaryImage(file.path) } }
        let firstBytes = try Data(contentsOf: first)
        expect("concurrent same-name captures allocate numbered folders without overwriting",
               colliding.allSatisfy { (try? Data(contentsOf: $0)) == firstBytes } && manager.fileExists(atPath: first.path))
        let pngFile = try NativeAppSnapshotImage.write(image, appName: String(repeating: "🙂", count: 300),
                                                  directory: directory, date: time, encoding: png)
        defer { Capture.removeTemporaryImage(pngFile.path) }
        let pngSource = CGImageSourceCreateWithURL(pngFile as CFURL, nil)
        let native = Dispatch.actionResponse(app: ownedApp, text: "", screenshotPath: pngFile.path, native: true)
        let screenshot = asDict(asDict(native["appSnapshot"])?["screenshot"])
        expect("native PNG uses the PNG MIME type and bounds long Unicode filenames",
               pngSource.flatMap { CGImageSourceGetType($0) } as String? == "public.png" &&
                   pngFile.lastPathComponent.utf8.count <= 255 && screenshot?["mimeType"] as? String == "image/png")
        let unowned = directory.appendingPathComponent("unowned.jpeg")
        try firstBytes.write(to: unowned)
        Capture.removeTemporaryImage(unowned.path)
        Capture.removeTemporaryImage(first.path)
        expect("native cleanup removes only paths created by this service",
               manager.fileExists(atPath: unowned.path) && !manager.fileExists(atPath: first.path))
    } catch {
        expect("native screenshot image fixture completes", false, String(describing: error))
    }

    let denied = ServiceError(.permissionsPending, "Screen Recording permission is required for Computer Use")
    let nativeDenial = Result { try AXCapture.captureImage(native: true) { throw denied } }
    if case .failure(let error) = nativeDenial {
        let nativeError = ComputerUseXPC.requestError(error)
        expect("native image failure reaches the wire with its service code and message",
               nativeError.code == CUErrorCode.permissionsPending.rawValue && nativeError.localizedDescription == denied.message)
    } else {
        expect("native image failure reaches the wire with its service code and message", false)
    }
    let nativeWriterFailure = Result {
        try AXCapture.captureImage(native: true) { throw CocoaError(.fileWriteOutOfSpace) }
    }
    if case .failure(let error) = nativeWriterFailure {
        expect("native writer failure preserves the underlying error", (error as? CocoaError)?.code == .fileWriteOutOfSpace)
    } else {
        expect("native writer failure preserves the underlying error", false)
    }
    let socketDenial = Result { try AXCapture.captureImage(native: false) { throw denied } }
    if case .success(nil) = socketDenial {
        expect("socket image failure allows an accessibility-only result", true)
    } else {
        expect("socket image failure allows an accessibility-only result", false)
    }

    let menuNodes = [
        "bar": ("AXMenuBar", "app"), "edit": ("AXMenuBarItem", "bar"),
        "menu": ("AXMenu", "edit"), "submenu": ("AXMenuItem", "menu"),
        "nested": ("AXMenu", "submenu"), "leaf": ("AXMenuItem", "nested"),
        "context": ("AXMenu", "window"), "window": ("AXWindow", "app"),
        "cycle": ("AXMenu", "cycle"), "orphan": ("AXMenuBarItem", "window"),
    ]
    func menuRoot(_ source: String) -> String? {
        AXMenuFocus.barItem(containing: source, role: { menuNodes[$0]?.0 }, parent: { menuNodes[$0]?.1 })
    }
    expect("a nested menu resolves to the bar item that owns it",
           menuRoot("leaf") == "edit" && menuRoot("edit") == "edit")
    expect("a context menu, detached menu item or cyclic ancestry cannot become the bar root",
           menuRoot("context") == nil && menuRoot("orphan") == nil && menuRoot("cycle") == nil)
    var menuFocus = AXMenuFocus<String>()
    menuFocus.opened(menuRoot("leaf"))
    menuFocus.opened(menuRoot("context"))
    expect("an unrelated menu notification leaves the focused item intact", menuFocus.root == "edit")
    var requestedImage = false
    let menuImage = Result {
        try AXCapture.captureImage(native: true, menuFocused: menuFocus.root != nil) {
            requestedImage = true
            throw denied
        }
    }
    if case .success(nil) = menuImage {
        expect("a focused native menu skips image capture and its permission check", !requestedImage)
    } else {
        expect("a focused native menu skips image capture and its permission check", false)
    }
    menuFocus.closed()
    let windowImage = Result { try AXCapture.captureImage(native: true, menuFocused: menuFocus.root != nil) { throw denied } }
    if case .failure(let error) = windowImage {
        expect("menu close restores the normal screenshot path", (error as? ServiceError)?.code == .permissionsPending)
    } else {
        expect("menu close restores the normal screenshot path", false)
    }

    var selectionSteps: [String] = []
    func pickMenu(_ item: String, focusError: ServiceError? = nil) throws -> Bool {
        try AXMenuFocus.selectBarItem(item, role: { menuNodes[$0]?.0 }, children: { parent in
            menuNodes.compactMap { $0.value.1 == parent ? $0.key : nil }
        }, enforceFocus: {
            selectionSteps.append("focus")
            if let focusError { throw focusError }
        }, commit: { root in
            selectionSteps.append("select")
            menuFocus.opened(root, synthetic: true)
        })
    }
    let selected = try? pickMenu("edit")
    expect("synthetic menu selection enforces window focus before committing the AX root",
           selected == true && selectionSteps == ["focus", "select"] && menuFocus.root == "edit")
    let declined = try? pickMenu("orphan")
    expect("a bar item with no menu child falls through without enforcing focus",
           declined == false && selectionSteps == ["focus", "select"])
    menuFocus.closeSynthetic()
    expect("a successful ordinary action clears synthetic menu focus", menuFocus.root == nil)
    menuFocus.opened("edit")
    menuFocus.closeSynthetic()
    expect("a physical menu remains under AX notification lifecycle", menuFocus.root == "edit")
    menuFocus.closed()
    selectionSteps.removeAll()
    let failedSelection = Result { try pickMenu("edit", focusError: denied) }
    if case .failure(let error) = failedSelection {
        expect("a synthetic focus failure leaves the menu unselected",
               (error as? ServiceError)?.code == .permissionsPending && selectionSteps == ["focus"] && menuFocus.root == nil)
    } else {
        expect("a synthetic focus failure leaves the menu unselected", false)
    }

    let menuWindows = [
        AXMenuWindowOrder.Window(id: 1, pid: 22, layer: 101),
        AXMenuWindowOrder.Window(id: 2, pid: 33, layer: 0),
        AXMenuWindowOrder.Window(id: 3, pid: 33, layer: 24),
        AXMenuWindowOrder.Window(id: 4, pid: 33, layer: 101),
    ]
    expect("menu ordering resolves the first matching owner and menu layer",
           AXMenuWindowOrder.menuWindow(ownedBy: 33, below: menuWindows) == 3)
    expect("menu ordering recognizes layer 101 and rejects an unrelated owner",
           AXMenuWindowOrder.menuWindow(ownedBy: 22, below: menuWindows) == 1 &&
           AXMenuWindowOrder.menuWindow(ownedBy: 44, below: menuWindows) == nil)
    expect("an observed window ahead of the foreground triggers a raise",
           AXMenuWindowOrder.needsRaise(2, observed: [3, 4], order: [1, 3, 2]))
    expect("a missing foreground or an observed window already behind it does not trigger a raise",
           !AXMenuWindowOrder.needsRaise(2, observed: [3], order: [1, 3]) &&
           !AXMenuWindowOrder.needsRaise(2, observed: [3], order: [1, 2, 3]))

    var trackedWindows = AXWindowMembership<String>()
    trackedWindows.track("window", id: 10)
    trackedWindows.track("sheet", id: 10)
    trackedWindows.remove("sheet")
    expect("window-ID upsert replaces the previous raw entry", trackedWindows.ids.isEmpty)
    trackedWindows.track("new window", id: 20)
    trackedWindows.track("new window", id: 21)
    expect("a raw reference can remain registered under distinct window IDs", trackedWindows.ids == [20, 21])
    trackedWindows.trackMenu("root menu", id: 30)
    trackedWindows.trackMenu("submenu", id: 31)
    trackedWindows.remove("window")
    expect("multiple menu windows stay observed when an unrelated reference is destroyed", trackedWindows.ids == [20, 21, 30, 31])
    trackedWindows.trackMenu("replacement menu", id: 21)
    trackedWindows.closeMenus()
    expect("session menu cleanup preserves only ordinary entries after keyed replacement", trackedWindows.ids == [20])

    let accessibilityTracker = AXAccessibilityTracker()
    var accessibilityChanges: [Bool] = []
    let firstAX = accessibilityTracker.acquire(process: "test:1", enable: {
        accessibilityChanges.append(true)
        return true
    }, restore: { accessibilityChanges.append(false) })
    let secondAX = accessibilityTracker.acquire(process: "test:1", enable: {
        accessibilityChanges.append(true)
        return true
    }, restore: { accessibilityChanges.append(false) })
    expect("overlapping AX assertions enable the process only once",
           firstAX?.changed == true && secondAX?.changed == false && accessibilityChanges == [true])
    firstAX?.0.release()
    firstAX?.0.release()
    expect("an overlapping assertion remains enabled after an idempotent release", accessibilityChanges == [true])
    secondAX?.0.release()
    expect("the last AX assertion restores the original setting", accessibilityChanges == [true, false])
    let failedAX = accessibilityTracker.acquire(process: "test:2", enable: { false }, restore: { accessibilityChanges.append(false) })
    var retriedAX = accessibilityTracker.acquire(process: "test:2", enable: { true }, restore: { accessibilityChanges.append(false) })
    expect("a failed AX assertion allows the same process to retry", failedAX == nil && retriedAX?.changed == true)
    retriedAX = nil
    expect("deinitializing a lease releases its AX assertion", accessibilityChanges == [true, false, false])
    expect("full UI contexts prefer advertised manual accessibility",
           AXAccessibility.kind(supportsManual: true, bundle: "com.spotify.client", fullContext: true) == .manual)
    expect("full UI contexts fall back to enhanced UI when manual accessibility is absent",
           AXAccessibility.kind(supportsManual: false, bundle: "test.fixture", fullContext: true) == .enhanced)
    expect("non-full contexts use enhanced UI only for the built-in bundle exceptions",
           AXAccessibility.kind(supportsManual: true, bundle: "com.apple.iWork.Pages", fullContext: false) == .enhanced &&
           AXAccessibility.kind(supportsManual: false, bundle: "com.spotify.client", fullContext: false) == .enhanced &&
           AXAccessibility.kind(supportsManual: false, bundle: "com.spotify.client.helper", fullContext: false) == nil &&
           AXAccessibility.kind(supportsManual: true, bundle: "test.fixture", fullContext: false) == nil)
    var restoredKinds: [AXAccessibility.Kind] = []
    let manualLease = accessibilityTracker.acquire(process: "test:3", kind: .manual, enable: { true },
                                                    restore: { restoredKinds.append(.manual) })
    let enhancedLease = accessibilityTracker.acquire(process: "test:3", kind: .enhanced, enable: { true },
                                                      restore: { restoredKinds.append(.enhanced) })
    manualLease?.0.release()
    enhancedLease?.0.release()
    expect("manual and enhanced assertions restore independently for one process",
           manualLease?.changed == true && enhancedLease?.changed == true && restoredKinds == [.manual, .enhanced])

    expect("VoiceOver selects the built-in persistent apps, browsers and contexts",
           AXVoiceOverPreference.mode(bundle: "com.microsoft.Excel", fullContext: false) == .persistent &&
           AXVoiceOverPreference.mode(bundle: "com.apple.Music", fullContext: false) == .persistent &&
           AXVoiceOverPreference.mode(bundle: "company.thebrowser.Browser", fullContext: true) == .pulse &&
           AXVoiceOverPreference.mode(bundle: "company.thebrowser.dia", fullContext: true) == .pulse &&
           AXVoiceOverPreference.mode(bundle: "company.thebrowser.dia", fullContext: false) == nil &&
           AXVoiceOverPreference.mode(bundle: "com.microsoft.Excel.Helper", fullContext: true) == nil)
    var preference = false
    var voiceOverRunning = false
    var preferenceWrites: [Bool] = []
    var preferenceNotifications = 0
    let voiceOverPreference = AXVoiceOverPreference(read: { preference }, write: {
        preference = $0
        preferenceWrites.append($0)
    }, notify: { preferenceNotifications += 1 }, voiceOverRunning: { voiceOverRunning })
    let excel = voiceOverPreference.acquire(process: "excel", mode: .persistent)
    let music = voiceOverPreference.acquire(process: "music", mode: .persistent)
    excel?.lease.release()
    expect("overlapping apps share VoiceOver enablement until the last release",
           excel?.changed == true && music?.changed == false && preference && preferenceWrites == [true])
    music?.lease.release()
    expect("the last VoiceOver release restores the preference and posts a notification",
           !preference && preferenceWrites == [true, false] && preferenceNotifications == 2)
    preference = true
    expect("a pre-existing enabled VoiceOver preference is left alone",
           voiceOverPreference.acquire(process: "existing", mode: .persistent) == nil && preferenceWrites == [true, false])
    preference = false
    let pendingVoiceOver = voiceOverPreference.acquire(process: "pending", mode: .persistent)
    voiceOverRunning = true
    pendingVoiceOver?.lease.release()
    expect("a running VoiceOver process prevents restoration",
           preference && preferenceWrites == [true, false, true] && preferenceNotifications == 3)
    voiceOverRunning = false
    preference = false
    let shutdownVoiceOver = voiceOverPreference.acquire(process: "shutdown", mode: .persistent)
    voiceOverPreference.shutdown()
    shutdownVoiceOver?.lease.release()
    expect("shutdown restores once and rejects later VoiceOver acquisitions",
           shutdownVoiceOver?.changed == true && !preference &&
           preferenceWrites == [true, false, true, true, false] && preferenceNotifications == 5 &&
           voiceOverPreference.acquire(process: "late", mode: .persistent) == nil)

    var settling = AXSettlingActivity<Int>(lastChange: 0)
    settling.recordTitle(nil, for: 1, at: 1)
    expect("a missing AX title does not restart the quiet period", settling.lastChange == 0)
    settling.recordTitle("", for: 1, at: 2)
    expect("a first empty AX title is a real change", settling.lastChange == 2)
    settling.recordTitle("", for: 1, at: 3)
    expect("duplicate AX titles do not restart the quiet period", settling.lastChange == 2)
    settling.recordTitle("", for: 2, at: 4)
    expect("identical AX titles are tracked independently for each element", settling.lastChange == 4)
    settling.recordTitle("Renamed", for: 1, at: 5)
    expect("a changed AX title restarts the quiet period", settling.lastChange == 5)
    expect("default settling polls web-shaped apps at 250 ms and other apps at 100 ms",
           AXSettler.Polling.applicationDefault.interval(isWebShaped: true) == 0.25 &&
           AXSettler.Polling.applicationDefault.interval(isWebShaped: false) == 0.1)
    var checkedBundle = false
    func checkedWebShape() -> Bool { checkedBundle = true; return true }
    let explicitInterval = AXSettler.Polling.tenthSecond.interval(isWebShaped: checkedWebShape())
    expect("the explicit action interval does not inspect the application bundle",
           explicitInterval == 0.1 && !checkedBundle)

    var settlingRoles = [0: "AXWindow", 1: "AXWebArea", 2: "AXBusyIndicator"]
    var settlingChildren = [0: [1], 1: [2]]
    var settlingAttributes: [Int: [String: Any]] = [:]
    func uiBusy(music: Bool = false, hasTime: Bool = true) -> Bool? {
        try? AXSettlingBusy.containsBusyElement(in: 0, music: music, role: { settlingRoles[$0] },
            children: { settlingChildren[$0] ?? [] }, attribute: { settlingAttributes[$0]?[$1] },
            canContinue: { hasTime })
    }
    expect("a busy descendant counts even when its WebArea has no AXLoaded", uiBusy() == true)
    settlingChildren[1] = [0]
    settlingAttributes[1] = ["AXElementBusy": true]
    expect("an unreadable AXLoaded skips the WebArea's own busy flag and cycles terminate", uiBusy() == false)
    settlingAttributes[1] = ["AXLoaded": 0]
    expect("a numeric AXLoaded is not an accessibility boolean", uiBusy() == false)
    settlingAttributes[1] = ["AXLoaded": false]
    expect("an explicitly unloaded WebArea is busy", uiBusy() == true)
    settlingAttributes[1] = ["AXLoaded": true, "AXElementBusy": true]
    expect("a loaded WebArea can still report AXElementBusy", uiBusy() == true)
    settlingAttributes[1] = ["AXLoaded": true, "AXDOMClassList": ["spinner"]]
    expect("DOM class names never mark a loaded WebArea busy", uiBusy() == false)
    settlingRoles = [0: "AXWindow", 1: "AXSplitGroup", 2: "AXScrollArea", 3: "AXList", 4: "AXButton"]
    settlingChildren = [0: [1], 1: [2], 2: [3]]
    settlingAttributes = [:]
    expect("only Music treats empty lists in its first split group's scroll area as loading",
           uiBusy(music: true) == true && uiBusy() == false)
    settlingChildren[3] = [4]
    expect("Music with populated lists is ready", uiBusy(music: true) == false)
    settlingChildren[2] = []
    expect("Music's completely empty scroll area is busy", uiBusy(music: true) == true)
    settlingChildren[2] = [4]
    expect("a button disqualifies Music's empty list test", uiBusy(music: true) == false)
    expect("an interrupted busy inspection cannot conclude readiness", uiBusy(hasTime: false) == true)

    let stageChildren = [0: [1, 2], 1: [0, 3], 2: [4]]
    let stageIDs: [Int: [UInt32]] = [1: [11], 2: [45], 3: [37, 42], 4: [42]]
    func stageEntry(_ id: UInt32) -> Int? {
        StageManagerCapture.entry(for: id, root: 0, windowIDs: { stageIDs[$0] ?? [] },
                                  children: { stageChildren[$0] ?? [] }, check: {})
    }
    expect("Stage Manager selects the first matching group in accessibility order despite a cycle",
           stageEntry(42) == 3 && stageEntry(45) == 2 && stageEntry(99) == nil)
    var stageEvents: [String] = []
    func simulateStage(first: Int?, second: Int?) {
        stageEvents = []
        var reads = 0
        StageManagerCapture.revealIfOffstage(find: {
            stageEvents.append("find")
            defer { reads += 1 }
            return reads == 0 ? first : second
        }, beforeReveal: { stageEvents.append("observe focus") }, unminimize: { stageEvents.append("unminimize") },
           wait: { stageEvents.append("wait") }, add: { stageEvents.append("add \($0)") })
    }
    simulateStage(first: nil, second: nil)
    expect("a window outside the Stage Manager shelf does not change focus or minimize state", stageEvents == ["find"])
    simulateStage(first: 1, second: nil)
    expect("unminimizing a window can remove the need for AXAddToStage",
           stageEvents == ["find", "observe focus", "unminimize", "wait", "find"])
    simulateStage(first: 1, second: 2)
    expect("Stage Manager acts on the current entry for a window still on the shelf",
           stageEvents == ["find", "observe focus", "unminimize", "wait", "find", "add 2"])
    enum StageProbeError: Error { case cancelled }
    var addedAfterCancellation = false
    do {
        try StageManagerCapture.revealIfOffstage(find: { 1 }, beforeReveal: {}, unminimize: {},
            wait: { throw StageProbeError.cancelled }, add: { _ in addedAfterCancellation = true })
        expect("Stage Manager propagates cancellation before adding the window", false)
    } catch {
        expect("Stage Manager propagates cancellation before adding the window", error is StageProbeError && !addedAfterCancellation)
    }

    // The actual artwork's anchor must land on the action coordinate. Check
    // primary and secondary displays, including negative global coordinates.
    let artwork = CursorOverlay.makeCursorArtwork()
    let tip = CGPoint(x: artwork.anchorPoint.x * artwork.bounds.width,
                      y: artwork.anchorPoint.y * artwork.bounds.height)
    let targets = [CGPoint(x: 900, y: 500), .zero, CGPoint(x: -1440, y: -200)]
    let tipsMatch = targets.allSatisfy { point in
        let frame = CursorOverlay.windowFrame(at: point, primaryHeight: 1080)
        return abs(frame.minX + tip.x - point.x) < 0.001 &&
               abs(frame.minY + tip.y - (1080 - point.y)) < 0.001
    }
    expect("cursor tip aligns with click across displays", tipsMatch)
    let host = CALayer()
    host.addSublayer(artwork)
    artwork.position = CGPoint(x: 200, y: 300)
    artwork.transform = CATransform3DConcat(CATransform3DMakeRotation(0.055, 0, 0, 1),
                                          CATransform3DMakeScale(0.94, 0.94, 1))
    let pressedTip = artwork.convert(tip, to: host)
    expect("cursor tip stays fixed while pressing and tilting",
           abs(pressedTip.x - 200) < 0.001 && abs(pressedTip.y - 300) < 0.001)
    let longMove = CursorOverlay.sampledMotionPath(from: .zero, to: CGPoint(x: 10000, y: 0))
    expect("cursor arc stays subtle on long moves", longMove.allSatisfy { abs($0.y) <= 18.001 })

    print("\n\(failures == 0 ? "ALL SELF-TESTS PASSED" : "\(failures) SELF-TEST FAILURE(S)")")
    return failures == 0 ? 0 : 1
}

@MainActor func run() {
    // Match application startup: configure the optional shared container before
    // admitting IPC requests. Diagnostic/self-test modes do not perform lookup.
    EventStreamStorageConfiguration.configureNative()
    AppUsageCatalog.shared.prewarm()
    let development = ProcessInfo.processInfo.environment[SenderAuthorization.developmentVariable] == "1"
    let foreground = ComputerUseNativeForegroundMonitor()
    let pip = RemoteHostedPIPService { AcuaSettings.features().remoteHostedPIP }
    Dispatch.installPIP(pip)
    let recordingControls = EventStreamRecordingControls(onRecordingEnded: { _, _ in
    })
    EventStreamRecordingOwner.onRecordingStateChanged = { recordingControls.refresh() }
    EventStreamRecordingOwner.onRecordingPolicyChanged = { recordingControls.refreshWarning() }
    EventStreamRecordingOwner.onObservedApplicationsChanged = { recordingControls.refreshApplications() }
    let workspace = NSWorkspace.shared.notificationCenter
    let terminationObserver = workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                     object: nil, queue: .main) { notification in
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let processKey = AppResolver.processKey(app)
        AXMenuSessions.processTerminated(processKey)
        AXAccessibility.processTerminated(processKey)
        AXIndex.shared.applicationTerminated(processKey: processKey)
        MainActor.assumeIsolated { Dispatch.removePIPApp(pid: app.processIdentifier) }
    }
    pip.prepare()
    NativeAppshotPermissions.configure()
    let xpc = ComputerUseXPCBootstrap(allow: { SenderAuthorization.shared.allows($0, development: development) },
        dispatch: { try Dispatch.handleXPC(peer: $0, type: $2, request: $3, metadata: $4, files: $5,
                                          returnActionAppSnapshot: $6, senderContext: $1, cancelled: $7) },
        foreground: foreground.updates,
        pipEndpoint: pip.endpoint,
        authorizeEvent: { try SenderAuthorization.shared.authorizeAppleEvent($0, development: development) })
    xpc.install()
    defer {
        EventStreamRecordingOwner.onRecordingStateChanged = nil
        EventStreamRecordingOwner.onRecordingPolicyChanged = nil
        EventStreamRecordingOwner.onObservedApplicationsChanged = nil
        xpc.stop()
        foreground.stop()
        workspace.removeObserver(terminationObserver)
        AXMenuSessions.endAll()
        AXVoiceOverPreference.shared?.shutdown()
        AXIndex.shared.shutdown()
    }
    var unixTransport: ServiceSocketTransport?
    defer { unixTransport?.stop(); unixTransport = nil }
    func shutdown() {
        unixTransport?.stop()
        xpc.stop()
        foreground.stop()
        TimelineNativeOwner.stopIfLoaded()
        EventStreamIPC.shutdownIfLoaded()
        SyntheticFocusSessions.endAll()
        AXMenuSessions.endAll()
        AXVoiceOverPreference.shared?.shutdown()
        AXIndex.shared.shutdown()
        exit(0)
    }

    // Development runs are explicitly launched and managed by their caller.
    let mode: ServiceClientLifetime.Mode? = development ? nil : .detect()
    let lifetime = mode.map { ServiceClientLifetime(mode: $0, onExit: shutdown) }
    let idleTimer = mode == .standalone ? ServiceIdleTimer(keepAlive: {
        EventStreamRecordingOwner.activeRecordingStatus != nil ||
            foreground.updates.hasSubscribers ||
            TimelineNativeOwner.isRunningOrPaused
    }, onIdle: shutdown) : nil
    Dispatch.idleTimer = idleTimer
    idleTimer?.reset()
    xpc.onPeerAdmitted = { lifetime?.admit($0) }
    lifetime?.start()
    defer {
        if Dispatch.idleTimer === idleTimer { Dispatch.idleTimer = nil }
        idleTimer?.stop()
        lifetime?.stop()
    }

    var shutdownSources: [DispatchSourceSignal] = []
    for number in [SIGTERM, SIGINT] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { shutdown() } }
        source.activate()
        shutdownSources.append(source)
    }
    defer { withExtendedLifetime(shutdownSources) {} }
    if ProcessInfo.processInfo.environment["ACUA_SERVICE_PROMPT_PERMISSIONS"] == "1" {
        let ax = Permissions.requestAccessibility()
        let sr = Permissions.screenRecordingGranted()
        FileHandle.standardError.write(Data("permissions: accessibility granted=\(ax) screenRecording granted=\(sr)\n".utf8))
        if !sr { Permissions.requestScreenRecording() }
    }
    // A missing shared container disables only the optional Unix listener;
    // the native XPC listener and application runloop remain available.
    if let path = defaultSocketPath() {
        unixTransport = makeSocketTransport(path: path, lifetime: lifetime)
        unixTransport?.start()
    }
    DispatchQueue.main.async { CursorOverlay.shared.prepare() }
    serviceApplication.run()
}

func makeSocketTransport(path: String, lifetime: ServiceClientLifetime? = nil) -> ServiceSocketTransport {
    let development = ProcessInfo.processInfo.environment[SenderAuthorization.developmentVariable] == "1"
    if development { FileHandle.standardError.write(Data("Development authorization: unsigned clients from the same local user are enabled\n".utf8)) }
    return ServiceSocketTransport(path: path, onError: { error in
        FileHandle.standardError.write(Data("AexComputerUseService: Socket listener: \(error)\n".utf8))
    }, onListening: {
        print("AexComputerUseService listening on \(path)")
    }, makeConnection: { [weak lifetime] io in
        guard let credentials = PeerAuditCredentials.read(fd: io.fd),
              SenderAuthorization.shared.allows(credentials, development: development) else {
            if ProcessInfo.processInfo.environment["ACUA_DIAGNOSTICS"] == "1" {
                FileHandle.standardError.write(Data("Connection rejected before frame decoding: sender authorization\n".utf8))
            }
            return nil
        }
        lifetime?.admit(credentials.pid)
        let connection = Connection(io: io, credentials: credentials,
                                    senderContext: SenderRequestContext.resolveNative(credentials.pid))
        return { connection.serve() }
    })
}

func serveForever(path: String, lifetime: ServiceClientLifetime? = nil) {
    let transport = makeSocketTransport(path: path, lifetime: lifetime)
    transport.start()
    transport.waitUntilStopped()
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("AexComputerUseService: \(message)\n").utf8))
    exit(1)
}

if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--capture" {
    let identifier = CommandLine.arguments[2]
    do {
        guard let resolved = AppResolver.resolve(identifier) else {
            throw ServiceError(.runningApplicationNotFound, "Not running: \(identifier)")
        }
        let captured = try Capture.captureWindow(pid: resolved.running.processIdentifier, into: URL(fileURLWithPath: NSTemporaryDirectory()))
        print(captured.path.path)
        print("size=\(captured.width)x\(captured.height)")
        exit(0)
    } catch let e as ServiceError {
        FileHandle.standardError.write(Data("capture failed: \(e.message) (\(e.code.rawValue))\n".utf8))
        exit(2)
    } catch {
        FileHandle.standardError.write(Data("capture failed: \(error.localizedDescription)\n".utf8))
        exit(2)
    }
}
if CommandLine.arguments.contains("--cursor-trace") {
    let a = CGPoint(x: 200, y: 200), b = CGPoint(x: 1200, y: 700)
    let pts = CursorOverlay.sampledMotionPath(from: a, to: b, steps: 10)
    print("bezier samples \(a) -> \(b):")
    for p in pts { print("  (\(Int(p.x)), \(Int(p.y)))") }
    // Perpendicular deviation from the straight chord proves it curves.
    let dx = b.x - a.x, dy = b.y - a.y, len = (dx*dx + dy*dy).squareRoot()
    let mid = pts[pts.count / 2]
    let dev = abs((mid.x - a.x) * dy - (mid.y - a.y) * dx) / len
    print("max-ish deviation at midpoint: \(String(format: "%.1f", dev)) pt")
    let short = CursorOverlay.sampledMotionPath(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0), steps: 4)
    print("short move stays straight: \(short.map { Int($0.y) })")
    exit(dev > 5 ? 0 : 1)
}
if CommandLine.arguments.contains("--cursor-hold") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        CursorOverlay.shared.place(at: CGPoint(x: 900, y: 500), active: true, animated: false)
        CursorOverlay.shared.debugState(label: "hold")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { exit(0) }
    }
    serviceApplication.run()
}
if CommandLine.arguments.contains("--cursor-demo") {
    // Deterministic overlay check inside a real AppKit runloop.
    let points: [CGPoint] = [CGPoint(x: 400, y: 300), CGPoint(x: 900, y: 500), CGPoint(x: 1400, y: 350), CGPoint(x: 700, y: 700)]
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        for (i, p) in points.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(i) * 1.1) {
                CursorOverlay.shared.place(at: p, active: true, animated: i > 0)
                CursorOverlay.shared.press()
                CursorOverlay.shared.debugState(label: "point \(i) \(p)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 + Double(points.count) * 1.1 + 0.6) {
            CursorOverlay.shared.hide()
            print("cursor demo done")
            exit(0)
        }
    }
    serviceApplication.run()
}
if CommandLine.arguments.contains("--permissions") {
    let ax = Permissions.accessibilityGranted()
    let sr = Permissions.screenRecordingGranted()
    print("accessibility=\(ax)")
    print("screenRecording=\(sr)")
    exit(0)
}
if CommandLine.arguments.contains("--check-input-monitor") {
    do {
        try UserInteractionMonitor.shared.ensureRunning()
        print(jsonString(["inputMonitorInstalled": true]))
        exit(0)
    } catch let error as ServiceError {
        print(jsonString(["inputMonitorInstalled": false, "code": error.code.rawValue, "message": error.message]))
        exit(1)
    } catch { fail(error.localizedDescription) }
}
if CommandLine.arguments.contains("--diagnostics") {
    let session = ScreenLockState.read()
    print(jsonString(["accessibility": Permissions.accessibilityGranted(),
                      "axWindowTargeting": AccessibilityWindowSPI.available,
                      "axActualPIDSelf": (try? AccessibilityWindowSPI.actualPID(AXUIElementCreateApplication(getpid()))) == getpid(),
                      "screenRecording": Permissions.screenRecordingGranted(),
                      "senderSigningTeamAvailable": SigningTeam.own() != nil,
                      "unsignedLocalClientsEnabled": ProcessInfo.processInfo.environment[SenderAuthorization.developmentVariable] == "1",
                      "permissionAccessoryAvailable": MainActor.assumeIsolated { AppshotPermissionAccessory.applicationBundleURL != nil },
                      "screenLocked": !session.interactionAvailable,
                      "screenLockState": session.state.rawValue,
                      "screenLockSource": session.source.rawValue,
                      "screenLockReason": session.reason,
                      "screenInteractionAvailable": session.interactionAvailable,
                      "onConsole": session.onConsole as Any? ?? NSNull(),
                      "displayCount": NSScreen.screens.count]))
    exit(0)
}
if CommandLine.arguments.contains("--prompt-permissions") {
    _ = Permissions.requestAccessibility()
    Permissions.requestScreenRecording()
    print("accessibility=\(Permissions.accessibilityGranted())")
    print("screenRecording=\(Permissions.screenRecordingGranted())")
    exit(0)
}
if CommandLine.arguments.contains("--selftest") {
    exit(runSelfTest())
}
MainActor.assumeIsolated { run() }
