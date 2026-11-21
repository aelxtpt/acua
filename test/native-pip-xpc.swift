import Foundation
import ObjectiveC
import XPC
import Darwin

@objc(OwnedPIPBootstrapProtocol) private protocol BootstrapProtocol {
    func endpoint(_ directory: String, reply: @escaping (NSXPCListenerEndpoint, Int32) -> Void)
    func shutdown(reply: @escaping () -> Void)
}
private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var rows = [[String: Any]]()
    var path: URL?
    func add(_ method: String, _ arguments: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        let row: [String: Any] = ["method": method, "arguments": arguments, "pid": getpid()]
        rows.append(row)
        if let path { try! JSONSerialization.data(withJSONObject: rows, options: .sortedKeys).write(to: path, options: .atomic) }
    }
    var values: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows }
}
private final class Replies: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0; private var errors = [NSError]()
    func record(_ error: NSError?) { lock.lock(); defer { lock.unlock() }; count += 1; if let error { errors.append(error) } }
    var snapshot: (Int, [NSError]) { lock.lock(); defer { lock.unlock() }; return (count, errors) }
}
private let presentation = "owned-配置-ç"
private struct OwnedMachMessage { var header = mach_msg_header_t(); var trailer = mach_msg_max_trailer_t() }
private func sendFenceAck(_ port: mach_port_t) -> kern_return_t {
    var header = mach_msg_header_t()
    header.msgh_bits = mach_msg_bits_t(MACH_MSG_TYPE_COPY_SEND)
    header.msgh_size = mach_msg_size_t(MemoryLayout<mach_msg_header_t>.size)
    header.msgh_remote_port = port; header.msgh_id = 0x504950
    let size = header.msgh_size
    return mach_msg(&header, mach_msg_option_t(MACH_SEND_MSG | MACH_SEND_TIMEOUT), size, 0, 0, 1000, 0)
}
private func receiveFenceAck(_ port: mach_port_t) -> Bool {
    var buffer = OwnedMachMessage()
    let result = withUnsafeMutablePointer(to: &buffer) { pointer in
        pointer.withMemoryRebound(to: mach_msg_header_t.self, capacity: 1) {
            mach_msg($0, mach_msg_option_t(MACH_RCV_MSG | MACH_RCV_TIMEOUT), 0, mach_msg_size_t(MemoryLayout<OwnedMachMessage>.size), port, 1000, 0)
        }
    }
    return result == KERN_SUCCESS && buffer.header.msgh_id == 0x504950
}
private final class Host: NSObject, RemoteHostedPIPContentHostXPCProtocol {
    let trace: Trace
    init(_ trace: Trace) { self.trace = trace }
    func publishPresentation(id: String, threadID: String, turnID: String, contextID: UInt32, width: Double, height: Double, reply: @escaping RemoteHostedPIPReply) {
        trace.add("publishPresentation", ["id": id, "thread": threadID, "turn": turnID, "context": contextID, "width": width, "height": height]); reply(nil)
    }
    func setSourceProcessIdentifier(_ pid: Int32, presentationID: String, reply: @escaping RemoteHostedPIPReply) { trace.add("sourcePID", ["pid": pid, "id": presentationID]); reply(nil) }
    func publishFrame(presentationID: String, videoData: Data, decoderConfiguration: Data?, codec: String, timestamp: UInt64, isKeyFrame: Bool, reply: @escaping RemoteHostedPIPReply) {
        trace.add("frame", ["id": presentationID, "video": Array(videoData), "configuration": decoderConfiguration.map { Array($0) as Any } ?? NSNull(), "codec": codec, "timestamp": String(timestamp), "key": isKeyFrame]); reply(nil)
    }
    func prepareOperation(presentationID: String, operationID: UInt64, kind: String, contextID: UInt32, width: Double, height: Double, fencePayload: RemoteHostedPIPFencePayload, reply: @escaping RemoteHostedPIPReply) {
        let port = xpc_dictionary_copy_mach_send(fencePayload, "owned_send_right")
        let sent = port != MACH_PORT_NULL ? sendFenceAck(port) : KERN_INVALID_NAME
        if port != MACH_PORT_NULL { mach_port_deallocate(mach_task_self_, port) }
        trace.add("prepare", ["id": presentationID, "operation": String(operationID), "kind": kind, "context": contextID, "width": width, "height": height,
            "dictionary": xpc_get_type(fencePayload) == XPC_TYPE_DICTIONARY, "token": xpc_dictionary_get_string(fencePayload, "token").map { String(cString: $0) } ?? "<missing>", "unsigned": String(xpc_dictionary_get_uint64(fencePayload, "unsigned")), "machSendResult": sent]); reply(nil)
    }
    func completeOperation(presentationID: String, operationID: UInt64, reply: @escaping RemoteHostedPIPReply) { trace.add("complete", ["id": presentationID, "operation": String(operationID)]); reply(nil) }
    func willEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply) { trace.add("willEnd", ["id": presentationID]); reply(nil) }
    func invalidatePresentation(id: String, reply: @escaping RemoteHostedPIPReply) { trace.add("invalidate", ["id": id]); reply(nil) }
    func noteInteraction(presentationID: String, reply: @escaping RemoteHostedPIPReply) { trace.add("interaction", ["id": presentationID]); reply(nil) }
    func setComputerUseCursorLocation(x: Double, y: Double, isActive: Bool, reply: @escaping RemoteHostedPIPReply) { trace.add("cursor", ["x": x, "y": y, "active": isActive]); reply(nil) }
}
private final class Producer: NSObject, RemoteHostedPIPContentProducerXPCProtocol {
    let trace: Trace
    weak var connection: NSXPCConnection?
    init(_ trace: Trace) { self.trace = trace }
    func connect(reply: @escaping RemoteHostedPIPReply) { trace.add("connect"); reply(nil) }
    func setMaxDisplaySize(_ size: Double, reply: @escaping RemoteHostedPIPReply) { trace.add("display", ["bits": String(size.bitPattern)]); reply(nil) }
    func setVideoMaxPixelDimension(_ dimension: Double, presentationID: String, reply: @escaping RemoteHostedPIPReply) { trace.add("videoDimension", ["dimension": dimension, "id": presentationID]); reply(nil) }
    func didEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply) { trace.add("didEnd", ["id": presentationID]); reply(nil) }
    func setPetLocation(x: Double, y: Double, available: Bool, reply: @escaping RemoteHostedPIPReply) { trace.add("pet", ["x": x, "y": y, "available": available]); reply(nil) }
    func performAction(presentationID: String, kind: String, reply: @escaping RemoteHostedPIPReply) {
        trace.add("action", ["id": presentationID, "kind": kind])
        if kind == "owned-error" { reply(NSError(domain: "OwnedPIPWire", code: 73, userInfo: ["owned": "value"])); return }
        guard let connection else { reply(NSError(domain: "OwnedPIPFixture", code: 1)); return }
        let group = DispatchGroup(), replies = Replies()
        guard let host = connection.remoteObjectProxyWithErrorHandler({ error in replies.record(error as NSError); group.leave() }) as? RemoteHostedPIPContentHostXPCProtocol else { reply(NSError(domain: "OwnedPIPFixture", code: 2)); return }
        let done: RemoteHostedPIPReply = { error in replies.record(error); group.leave() }
        group.enter(); host.publishPresentation(id: presentation, threadID: "owned-thread", turnID: "owned-turn", contextID: .max, width: 640.25, height: 480.5, reply: done)
        group.enter(); host.setSourceProcessIdentifier(.max, presentationID: presentation, reply: done)
        group.enter(); host.publishFrame(presentationID: presentation, videoData: Data([0,1,2,255]), decoderConfiguration: nil, codec: "h264", timestamp: .max, isKeyFrame: true, reply: done)
        group.enter(); host.publishFrame(presentationID: presentation, videoData: Data(), decoderConfiguration: Data([3,4]), codec: "hevc", timestamp: 0, isKeyFrame: false, reply: done)
        let fence = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(fence, "token", "owned-fence"); xpc_dictionary_set_uint64(fence, "unsigned", .max)
        var port: mach_port_t = mach_port_t(MACH_PORT_NULL)
        precondition(mach_port_allocate(mach_task_self_, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), &port) == KERN_SUCCESS)
        precondition(mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS)
        let ownedPort = port
        xpc_dictionary_set_mach_send(fence, "owned_send_right", ownedPort)
        group.enter(); host.prepareOperation(presentationID: presentation, operationID: .max, kind: "resize", contextID: .max, width: 0, height: -0.25, fencePayload: fence as! RemoteHostedPIPFencePayload, reply: done)
        group.enter(); host.completeOperation(presentationID: presentation, operationID: .max, reply: done)
        group.enter(); host.willEndStream(presentationID: presentation, reply: done)
        group.enter(); host.invalidatePresentation(id: presentation, reply: done)
        group.enter(); host.noteInteraction(presentationID: presentation, reply: done)
        group.enter(); host.setComputerUseCursorLocation(x: -12.5, y: 83.75, isActive: false, reply: done)
        group.notify(queue: .global()) {
            let received = receiveFenceAck(ownedPort)
            mach_port_deallocate(mach_task_self_, ownedPort)
            mach_port_mod_refs(mach_task_self_, ownedPort, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), -1)
            self.trace.add("fenceAck", ["received": received])
            self.trace.add("hostReplies", ["count": replies.snapshot.0, "errors": replies.snapshot.1.count])
            reply(replies.snapshot.1.first)
        }
    }
}
private final class ProducerDelegate: NSObject, NSXPCListenerDelegate {
    let trace: Trace; var connections = [NSXPCConnection]()
    init(_ trace: Trace) { self.trace = trace }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let producer = Producer(trace); producer.connection = connection
        connection.exportedInterface = RemoteHostedPIPXPC.producerInterface(); connection.exportedObject = producer
        connection.remoteObjectInterface = RemoteHostedPIPXPC.hostInterface(); connections.append(connection); connection.activate(); return true
    }
}
private final class Bootstrap: NSObject, BootstrapProtocol {
    let listener: NSXPCListener, trace: Trace
    init(_ listener: NSXPCListener, _ trace: Trace) { self.listener = listener; self.trace = trace }
    func endpoint(_ directory: String, reply: @escaping (NSXPCListenerEndpoint, Int32) -> Void) { trace.path = URL(fileURLWithPath: directory).appendingPathComponent("producer.json"); reply(listener.endpoint, getpid()) }
    func shutdown(reply: @escaping () -> Void) { reply(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) } }
}
private final class BootstrapDelegate: NSObject, NSXPCListenerDelegate {
    let object: Bootstrap; var connections = [NSXPCConnection]()
    init(_ object: Bootstrap) { self.object = object }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: BootstrapProtocol.self); connection.exportedObject = object
        connections.append(connection); connection.activate(); return true
    }
}
private func protocolMetadata() -> [String: Any] {
    var result = [String: Any]()
    for (name, value) in [("host", RemoteHostedPIPContentHostXPCProtocol.self as Protocol), ("producer", RemoteHostedPIPContentProducerXPCProtocol.self as Protocol)] {
        var count: UInt32 = 0
        let methods = protocol_copyMethodDescriptionList(value, true, true, &count)!
        defer { free(methods) }
        result[name] = (0..<Int(count)).map { ["selector": NSStringFromSelector(methods[$0].name!), "types": String(cString: methods[$0].types!)] }
    }
    result["dictionaryConfigured"] = RemoteHostedPIPXPC.hostInterface().xpcType(for: RemoteHostedPIPXPC.fenceSelector, argumentIndex: 6, ofReply: false) == XPC_TYPE_DICTIONARY
    return result
}
@main enum Tests {
    static func main() throws {
        if Bundle.main.bundleIdentifier?.hasSuffix(".child") == true {
            let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            try JSONSerialization.data(withJSONObject: ["pid": getpid(), "executable": Bundle.main.executableURL!.path]).write(to: root.appendingPathComponent("child-pid.json"))
            let trace = Trace(), listener = NSXPCListener.anonymous(), producer = ProducerDelegate(trace)
            listener.delegate = producer; listener.activate()
            let bootstrap = Bootstrap(listener, trace), delegate = BootstrapDelegate(bootstrap), service = NSXPCListener.service()
            service.delegate = delegate
            withExtendedLifetime((producer, delegate, bootstrap, listener)) { service.resume(); dispatchMain() }
        }
        if CommandLine.arguments.dropFirst().first == "--protocols" {
            print(String(decoding: try JSONSerialization.data(withJSONObject: protocolMetadata(), options: .sortedKeys), as: UTF8.self)); return
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]), corpus = URL(fileURLWithPath: CommandLine.arguments[2])
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            guard value() else { fputs("FAIL: \(label)\n", stderr); exit(1) }; checks += 1; print("PASS: \(label)")
        }
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: corpus)) as! [String: [[String: String]]]
        let actual = protocolMetadata()
        for role in ["host", "producer"] {
            let rows = actual[role] as! [[String: String]]
            check(Dictionary(uniqueKeysWithValues: rows.map { ($0["selector"]!, $0["types"]!) }) == Dictionary(uniqueKeysWithValues: expected[role]!.map { ($0["selector"]!, $0["types"]!) }), "\(role) selectors and native argument encodings match")
        }
        check(actual["dictionaryConfigured"] as? Bool == true, "native fence argument is configured as XPC dictionary at index6")
        let broker = NSXPCConnection(serviceName: Bundle.main.bundleIdentifier! + ".child")
        broker.remoteObjectInterface = NSXPCInterface(with: BootstrapProtocol.self); broker.activate()
        var brokerError: Error?, endpoint: NSXPCListenerEndpoint?, remotePID: Int32 = 0
        let bootstrap = broker.synchronousRemoteObjectProxyWithErrorHandler { brokerError = $0 } as! BootstrapProtocol
        bootstrap.endpoint(directory.path) { endpoint = $0; remotePID = $1 }
        check(brokerError == nil && endpoint != nil && remotePID != getpid() && remotePID > 0, "owned XPC service transfers anonymous endpoint from a distinct process")
        defer { bootstrap.shutdown {}; broker.invalidate() }
        let trace = Trace(); trace.path = directory.appendingPathComponent("host.json")
        let connection = NSXPCConnection(listenerEndpoint: endpoint!)
        connection.exportedInterface = RemoteHostedPIPXPC.hostInterface(); connection.exportedObject = Host(trace)
        connection.remoteObjectInterface = RemoteHostedPIPXPC.producerInterface(); connection.activate(); defer { connection.invalidate() }
        var transportError: Error?, transportErrorCount = 0
        let producer = connection.synchronousRemoteObjectProxyWithErrorHandler { transportError = $0; transportErrorCount += 1 } as! RemoteHostedPIPContentProducerXPCProtocol
        func call(_ label: String, _ body: (@escaping RemoteHostedPIPReply) -> Void) {
            var replies = 0; var error: NSError?; body { replies += 1; error = $0 }
            check(transportError == nil && replies == 1 && error == nil, "native producer \(label) replies once over anonymous XPC")
        }
        call("connect") { producer.connect(reply: $0) }
        for size in [200.5, Double.infinity, Double.nan] { call("display bits=\(size.bitPattern)") { producer.setMaxDisplaySize(size, reply: $0) } }
        call("video dimension") { producer.setVideoMaxPixelDimension(4096.5, presentationID: presentation, reply: $0) }
        call("all host messages") { producer.performAction(presentationID: presentation, kind: "exercise-host", reply: $0) }
        var domainError: NSError?, errorReplies = 0
        producer.performAction(presentationID: presentation, kind: "owned-error") { domainError = $0; errorReplies += 1 }
        check(transportError == nil && errorReplies == 1 && domainError?.domain == "OwnedPIPWire" && domainError?.code == 73 && domainError?.userInfo["owned"] as? String == "value", "native NSError domain code and userInfo survive reply serialization")
        call("end stream") { producer.didEndStream(presentationID: presentation, reply: $0) }
        call("pet location") { producer.setPetLocation(x: -7.25, y: 19.5, available: true, reply: $0) }
        let hostRows = trace.values
        check(hostRows.count == 10 && Set(hostRows.compactMap { $0["method"] as? String }).count == 9, "all nine host selectors and both frame forms arrive across processes")
        func arguments(_ method: String) -> [String: Any] { hostRows.first { $0["method"] as? String == method }!["arguments"] as! [String: Any] }
        let prepared = arguments("prepare")
        check(prepared["dictionary"] as? Bool == true && prepared["token"] as? String == "owned-fence" && prepared["unsigned"] as? String == String(UInt64.max) && prepared["operation"] as? String == String(UInt64.max), "real XPC fence dictionary and UInt64 boundary survive native transport")
        let published = arguments("publishPresentation")
        check(published["id"] as? String == presentation && published["context"] as? UInt32 == .max && published["width"] as? Double == 640.25 && published["height"] as? Double == 480.5, "Unicode identifiers UInt32 boundary and dimensions survive native transport")
        let frames = hostRows.filter { $0["method"] as? String == "frame" }.map { $0["arguments"] as! [String: Any] }
        check(frames[0]["video"] as? [UInt8] == [0,1,2,255] && frames[0]["configuration"] is NSNull && frames[0]["timestamp"] as? String == String(UInt64.max) && frames[0]["key"] as? Bool == true && frames[1]["configuration"] as? [UInt8] == [3,4] && frames[1]["video"] as? [UInt8] == [], "binary frame bytes nil and present decoder data and timestamp boundary survive")
        let producerRows = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("producer.json"))) as! [[String: Any]]
        let sizes = producerRows.filter { $0["method"] as? String == "display" }.map { ($0["arguments"] as! [String: Any])["bits"] as! String }
        check(sizes == [200.5, Double.infinity, Double.nan].map { String($0.bitPattern) }, "finite infinite and NaN Double bits cross XPC unchanged")
        let hostReplies = producerRows.first { $0["method"] as? String == "hostReplies" }!["arguments"] as! [String: Any]
        check(hostReplies["count"] as? Int == 10 && hostReplies["errors"] as? Int == 0, "all ten host calls reply exactly once without transport errors")
        let fenceAck = producerRows.first { $0["method"] as? String == "fenceAck" }!["arguments"] as! [String: Any]
        check(prepared["machSendResult"] as? Int32 == KERN_SUCCESS && fenceAck["received"] as? Bool == true, "fence payload transfers a real Mach send right and acknowledgement across processes")
        check(connection.processIdentifier == remotePID && producerRows.allSatisfy { $0["pid"] as? Int32 == remotePID } && hostRows.allSatisfy { $0["pid"] as? Int32 == getpid() }, "native peer PID and both receiver traces prove separate-process delivery")
        let source = arguments("sourcePID"), cursor = arguments("cursor"), complete = arguments("complete")
        check(source["pid"] as? Int32 == .max && cursor["x"] as? Double == -12.5 && cursor["y"] as? Double == 83.75 && cursor["active"] as? Bool == false && complete["operation"] as? String == String(UInt64.max) && prepared["kind"] as? String == "resize" && prepared["height"] as? Double == -0.25 && published["thread"] as? String == "owned-thread" && published["turn"] as? String == "owned-turn", "host control messages preserve signed IDs flags coordinates and operation context")
        let dimension = producerRows.first { $0["method"] as? String == "videoDimension" }!["arguments"] as! [String: Any]
        let pet = producerRows.first { $0["method"] as? String == "pet" }!["arguments"] as! [String: Any]
        check(dimension["dimension"] as? Double == 4096.5 && dimension["id"] as? String == presentation && pet["x"] as? Double == -7.25 && pet["y"] as? Double == 19.5 && pet["available"] as? Bool == true && producerRows.filter { $0["method"] as? String == "action" }.count == 2 && hostRows.allSatisfy { row in let args = row["arguments"] as! [String: Any]; return args["id"] == nil || args["id"] as? String == presentation }, "producer controls and presentation identities keep their wire values")
        connection.invalidate()
        var closedReplies = 0
        producer.connect { _ in closedReplies += 1 }
        check(transportErrorCount == 1 && transportError != nil && closedReplies == 0, "invalidated anonymous connection reports one transport error without a reply")
        try JSONSerialization.data(withJSONObject: ["status": "passed", "checks": checks, "hostPID": getpid(), "producerPID": remotePID, "hostMessages": hostRows.count, "producerMessages": producerRows.count], options: .sortedKeys).write(to: directory.appendingPathComponent("result.json"))
        print("Native PIP XPC checks: \(checks)")
    }
}
