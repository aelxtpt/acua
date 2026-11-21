import Foundation
import ObjectiveC
import QuartzCore
import XPC
import Darwin

private func field(_ object: Any, _ name: String) -> Any? { Mirror(reflecting: object).children.first { $0.label == name }?.value }
private typealias GetLayer = @convention(c) (NSObject, Selector) -> Unmanaged<CALayer>?
private func attached(_ context: NSObject) -> CALayer? {
    let selector = NSSelectorFromString("layer")
    return unsafeBitCast(context.method(for: selector), to: GetLayer.self)(context, selector)?.takeUnretainedValue()
}
private func portState(_ port: mach_port_t) -> [String: Any] {
    var count: mach_port_urefs_t = 0, type: mach_port_type_t = 0
    let result = mach_port_get_refs(mach_task_self_, port, mach_port_right_t(MACH_PORT_RIGHT_SEND), &count)
    let typeCode = mach_port_type(mach_task_self_, port, &type)
    return ["code": result, "count": count, "typeCode": typeCode, "type": type]
}
private func ownedPixels(_ layer: CALayer) -> [UInt8] {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    layer.bounds = CGRect(x: 0, y: 0, width: 8, height: 8)
    layer.backgroundColor = CGColor(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
    CATransaction.commit()
    var bytes = [UInt8](repeating: 0, count: 256)
    bytes.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        layer.render(in: context)
    }
    return bytes
}

private final class Factory: NSObject {
    static var next: NSObject?, calls = 0, lastConnection: UInt32 = 0, lastOptions: NSDictionary?
    @objc(contextWithCGSConnection:options:) class func make(_ connection: UInt32, options: NSDictionary) -> AnyObject? {
        calls += 1; lastConnection = connection; lastOptions = options; return next
    }
}
private class ContextIDOnly: NSObject { @objc func contextId() -> UInt32 { 0 } }
private class ContextLayerOnly: NSObject { @objc(setLayer:) func setLayer(_ layer: CALayer?) {} }
private class BasicContext: ContextIDOnly {
    var attached: CALayer?, setCalls = 0
    @objc(setLayer:) func setLayer(_ layer: CALayer?) { attached = layer; setCalls += 1 }
}
private class CreateOnly: BasicContext {
    var fenceCalls = 0
    @objc func createFencePort() -> UInt32 { fenceCalls += 1; return 0 }
}
private final class FullContext: CreateOnly { @objc(setFencePort:) func setFence(_ port: UInt32) {} }
private final class SetterOnly: BasicContext { @objc(setFencePort:) func setFence(_ port: UInt32) {} }

@main @MainActor private enum Tests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        guard value() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        checks += 1; print("PASS: \(label)")
    }
    static func guards() throws {
        var queried = false
        check(RemoteHostedPIPLayerContext.create(contextClass: nil, connection: { queried = true; return 1 }) == nil && !queried,
            "missing context class does not query the WindowServer connection")
        check(RemoteHostedPIPLayerContext.create(contextClass: NSObject.self, connection: { queried = true; return 1 }) == nil && !queried,
            "unsupported class factory does not query the WindowServer connection")
        Factory.calls = 0
        check(RemoteHostedPIPLayerContext.create(contextClass: Factory.self, connection: nil) == nil && Factory.calls == 0,
            "unavailable connection import leaves the factory unused")
        Factory.next = nil
        check(RemoteHostedPIPLayerContext.create(contextClass: Factory.self, connection: { 42 }) == nil,
            "nil native context is reported unavailable")
        Factory.next = ContextLayerOnly()
        check(RemoteHostedPIPLayerContext.create(contextClass: Factory.self, connection: { 42 }) == nil,
            "native context must expose contextId")
        Factory.next = ContextIDOnly()
        check(RemoteHostedPIPLayerContext.create(contextClass: Factory.self, connection: { 42 }) == nil,
            "native context must expose setLayer")
        let basic = BasicContext(); Factory.next = basic
        let wrapper = RemoteHostedPIPLayerContext.create(contextClass: Factory.self, connection: { UInt32.max })!
        check(Factory.lastConnection == .max && Factory.lastOptions?.count == 0, "factory forwards the unsigned connection and empty options")
        check(wrapper.contextID == 0 && basic.attached === wrapper.rootLayer && basic.setCalls == 1,
            "zero context ID is retained and root layer is attached once")
        check(wrapper.createFencePort() == 0, "missing optional fence methods return a null port")
        wrapper.invalidate(); wrapper.invalidate()
        check(basic.attached == nil && basic.setCalls == 3, "each invalidation detaches the layer while retaining the wrapper")
        let createOnly = CreateOnly(); Factory.next = createOnly
        let noSetter = RemoteHostedPIPLayerContext.create(contextClass: Factory.self, connection: { 1 })!
        check(noSetter.createFencePort() == 0 && createOnly.fenceCalls == 0, "fence creation checks setter capability before allocating a right")
        Factory.next = SetterOnly()
        check(RemoteHostedPIPLayerContext.create(contextClass: Factory.self, connection: { 1 })!.createFencePort() == 0,
            "setter without fence creation is unsupported")
        let full = FullContext(); Factory.next = full
        let supported = RemoteHostedPIPLayerContext.create(contextClass: Factory.self, connection: { 1 })!
        let producer = try RemoteHostedPIPContentProducer(contextFactory: { supported })
        check(producer.createFence() == nil && full.fenceCalls == 1, "native null fence result does not create an owning lease")
        do { _ = try RemoteHostedPIPContentProducer(contextFactory: { nil }); check(false, "missing context must throw") }
        catch {
            let error = error as NSError
            check(error.code == 0 && error.userInfo.isEmpty && error.domain.hasPrefix("ComputerUse.RemoteHostedPIPContentProducer."),
                "producer construction failure keeps its error shape and code")
        }
        Factory.next = nil
    }

    static func compare(_ expected: [String: Any]) throws -> [String: Any] {
        let producer = try RemoteHostedPIPContentProducer(), root = producer.rootLayer
        let wrapper = field(producer, "context") as! RemoteHostedPIPLayerContext
        let context = field(wrapper, "context") as! NSObject
        let id = producer.contextID
        var facts: [String: Any] = ["contextIDNonzero": id != 0, "rootLayerClass": String(describing: type(of: root)),
            "rootInitiallyAttached": attached(context) === root, "rootBoundsInitiallyEmpty": root.bounds == .zero,
            "rootInitialSublayers": root.sublayers?.count ?? 0]
        var fence = producer.createFence()
        check(fence != nil, "actual native graphics context creates a real fence")
        let port = fence!.port
        var trace = [[String: Any]]()
        func sample(_ phase: String) { var value = portState(port); value["phase"] = phase; trace.append(value) }
        sample("created"); producer.setFence(fence!); sample("set")
        var payload: RemoteHostedPIPFencePayload? = fence!.payload(); sample("payload")
        check(xpc_get_type(payload!) == XPC_TYPE_DICTIONARY && xpc_dictionary_get_count(payload!) == 1,
            "native fence payload has a single dictionary entry")
        let copied = xpc_dictionary_copy_mach_send(payload!, "fence"); sample("copied")
        check(copied == port, "fence dictionary preserves the actual local graphics right")
        mach_port_deallocate(mach_task_self_, copied); sample("copy-released")
        autoreleasepool { fence = nil }; sample("fence-released")
        autoreleasepool { payload = nil }; sample("payload-released")
        facts["pixels"] = ownedPixels(root)
        producer.invalidate()
        facts["layerDetachedAfterInvalidate"] = attached(context) == nil
        facts["contextIDStableAfterInvalidate"] = producer.contextID == id
        facts["rootRetainedAfterInvalidate"] = producer.rootLayer === root
        producer.invalidate(); facts["secondInvalidateStillDetached"] = attached(context) == nil
        let expectedFacts = expected["facts"] as! [String: Any]
        for key in expectedFacts.keys.sorted() { check(NSDictionary(dictionary: [key: facts[key]!]).isEqual(to: [key: expectedFacts[key]!]), "graphics fact matches \(key)") }
        let expectedTrace = expected["portTrace"] as! [[String: Any]]
        check(trace.count == expectedTrace.count, "graphics-right lifetime has the same phase count")
        for (expectedPhase, actual) in zip(expectedTrace, trace) {
            check(NSDictionary(dictionary: expectedPhase).isEqual(to: actual), "graphics-right ownership matches \(actual["phase"]!)")
        }
        return ["facts": facts, "portTrace": trace, "rawContextID": id, "rawFencePort": port]
    }

    @MainActor static func main() async throws {
        if Bundle.main.bundleIdentifier?.hasSuffix(".child") == true { runChild(); return }
        let packaged = Bundle.main.bundleIdentifier != nil
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[packaged ? 2 : 1]))) as! [String: Any]
        try guards()
        let actual = try compare(corpus["expected"] as! [String: Any])
        if packaged {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1])
            try JSONSerialization.data(withJSONObject: actual, options: .sortedKeys).write(to: directory.appendingPathComponent("layer-result.json"))
            await native(directory)
        }
        print("Native PIP layer context checks: \(checks)")
    }
}

@objc(OwnedPIPLayerBootstrap) private protocol BootstrapProtocol {
    func endpoint(reply: @escaping (NSXPCListenerEndpoint, Int32) -> Void)
    func snapshot(reply: @escaping (Data) -> Void)
    func shutdown(reply: @escaping () -> Void)
}

@MainActor private final class Driver: NSObject, RemoteHostedPIPConnectionOwner {
    let producer = try! RemoteHostedPIPContentProducer()
    var transport: RemoteHostedPIPConnection!
    var setFenceApplied = false, completions = 0
    func resetRemoteHostedStreams() {}
    func enqueueRemoteHostedStreamsAndCursorReplay() {}
    func clearRemoteHostedPetLocation() {}
    nonisolated func connect(reply: @escaping RemoteHostedPIPReply) { Task { @MainActor in self.transport.didCompleteHandshake() }; reply(nil) }
    nonisolated func setMaxDisplaySize(_ size: Double, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    nonisolated func setVideoMaxPixelDimension(_ dimension: Double, presentationID: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    nonisolated func didEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    nonisolated func setPetLocation(x: Double, y: Double, available: Bool, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    nonisolated func performAction(presentationID: String, kind: String, reply: @escaping RemoteHostedPIPReply) {
        Task { @MainActor in
            guard let connection = self.transport.connection, let fence = self.producer.createFence() else { reply(NSError(domain: "OwnedPIPLayer", code: 1)); return }
            _ = ownedPixels(self.producer.rootLayer)
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let host = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! RemoteHostedPIPContentHostXPCProtocol
                    host.prepareOperation(presentationID: presentationID, operationID: 1, kind: "resize", contextID: self.producer.contextID,
                        width: 8, height: 8, fencePayload: fence.payload()) { error in
                            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                        }
                }
                self.producer.setFence(fence); self.setFenceApplied = true
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let host = connection.remoteObjectProxyWithErrorHandler { continuation.resume(throwing: $0) } as! RemoteHostedPIPContentHostXPCProtocol
                    host.completeOperation(presentationID: presentationID, operationID: 1) { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                }
                self.completions += 1; reply(nil)
            } catch { reply(error as NSError) }
        }
    }
}

@MainActor private final class Bootstrap: NSObject, BootstrapProtocol {
    let driver: Driver
    init(_ driver: Driver) { self.driver = driver }
    nonisolated func endpoint(reply: @escaping (NSXPCListenerEndpoint, Int32) -> Void) { Task { @MainActor in reply(self.driver.transport.endpointForHostConnection(), getpid()) } }
    nonisolated func snapshot(reply: @escaping (Data) -> Void) {
        Task { @MainActor in
            reply(try! JSONSerialization.data(withJSONObject: ["contextID": self.driver.producer.contextID,
                "setFenceApplied": self.driver.setFenceApplied, "completions": self.driver.completions,
                "connected": self.driver.transport.connection != nil, "peerPID": self.driver.transport.connection?.processIdentifier ?? -1, "pid": getpid()], options: .sortedKeys))
        }
    }
    nonisolated func shutdown(reply: @escaping () -> Void) { reply(); DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exit(0) } }
}

private final class BootstrapDelegate: NSObject, NSXPCListenerDelegate {
    let object: Bootstrap; var connections = [NSXPCConnection]()
    init(_ object: Bootstrap) { self.object = object }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: BootstrapProtocol.self); connection.exportedObject = object
        connections.append(connection); connection.activate(); return true
    }
}

private final class Host: NSObject, RemoteHostedPIPContentHostXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var rows = [[String: Any]]()
    var values: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows }
    func prepareOperation(presentationID: String, operationID: UInt64, kind: String, contextID: UInt32, width: Double, height: Double, fencePayload: RemoteHostedPIPFencePayload, reply: @escaping RemoteHostedPIPReply) {
        let first = xpc_dictionary_copy_mach_send(fencePayload, "fence"), second = xpc_dictionary_copy_mach_send(fencePayload, "fence")
        let info = portState(first)
        if first != 0 { mach_port_deallocate(mach_task_self_, first) }
        if second != 0 { mach_port_deallocate(mach_task_self_, second) }
        lock.lock(); rows.append(["method": "prepare", "id": presentationID, "operation": String(operationID), "kind": kind,
            "contextID": contextID, "width": width, "height": height, "entryCount": Int(xpc_dictionary_get_count(fencePayload)),
            "sameRight": first != 0 && first == second, "right": info, "pid": getpid()]); lock.unlock()
        // The graphical fence is inspected and released; no arbitrary Mach
        // message is sent to its WindowServer endpoint.
        reply(nil)
    }
    func completeOperation(presentationID: String, operationID: UInt64, reply: @escaping RemoteHostedPIPReply) {
        lock.lock(); rows.append(["method": "complete", "id": presentationID, "operation": String(operationID), "pid": getpid()]); lock.unlock(); reply(nil)
    }
    func publishPresentation(id: String, threadID: String, turnID: String, contextID: UInt32, width: Double, height: Double, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func setSourceProcessIdentifier(_ pid: Int32, presentationID: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func publishFrame(presentationID: String, videoData: Data, decoderConfiguration: Data?, codec: String, timestamp: UInt64, isKeyFrame: Bool, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func willEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func invalidatePresentation(id: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func noteInteraction(presentationID: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func setComputerUseCursorLocation(x: Double, y: Double, isActive: Bool, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
}

private extension Tests {
    static func runChild() {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try! JSONSerialization.data(withJSONObject: ["pid": getpid(), "executable": Bundle.main.executableURL!.path]).write(to: root.appendingPathComponent("child-pid.json"))
        let driver = Driver(); driver.transport = RemoteHostedPIPConnection(owner: driver)
        let object = Bootstrap(driver), delegate = BootstrapDelegate(object), listener = NSXPCListener.service()
        listener.delegate = delegate
        withExtendedLifetime((driver, object, delegate, listener)) { listener.resume(); dispatchMain() }
    }
    static func native(_ directory: URL) async {
        let broker = NSXPCConnection(serviceName: Bundle.main.bundleIdentifier! + ".child")
        broker.remoteObjectInterface = NSXPCInterface(with: BootstrapProtocol.self); broker.activate()
        let bootstrap = broker.remoteObjectProxyWithErrorHandler { error in fputs("Layer bootstrap error: \(error)\n", stderr); exit(1) } as! BootstrapProtocol
        defer { bootstrap.shutdown {}; broker.invalidate() }
        let (endpoint, pid): (NSXPCListenerEndpoint, Int32) = await withCheckedContinuation { continuation in bootstrap.endpoint { continuation.resume(returning: ($0,$1)) } }
        check(pid > 0 && pid != getpid(), "graphics producer and receiver use distinct owned processes")
        let host = Host(), connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.exportedInterface = RemoteHostedPIPXPC.hostInterface(); connection.exportedObject = host
        connection.remoteObjectInterface = RemoteHostedPIPXPC.producerInterface(); connection.activate(); defer { connection.invalidate() }
        let producer = connection.remoteObjectProxyWithErrorHandler { error in fputs("Layer transport error: \(error)\n", stderr); exit(1) } as! RemoteHostedPIPContentProducerXPCProtocol
        let connectError: NSError? = await withCheckedContinuation { continuation in producer.connect { continuation.resume(returning: $0) } }
        check(connectError == nil, "native graphics fixture acknowledges connection")
        func snapshot() async -> [String: Any] {
            let data: Data = await withCheckedContinuation { continuation in bootstrap.snapshot { continuation.resume(returning: $0) } }
            return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        }
        var before = await snapshot()
        for _ in 0..<100 where before["connected"] as? Bool != true { try? await Task.sleep(nanoseconds: 1_000_000); before = await snapshot() }
        check(before["connected"] as? Bool == true && before["peerPID"] as? Int32 == getpid() && connection.processIdentifier == pid,
            "native graphics channel records actual kernel peer identifiers")
        let error: NSError? = await withCheckedContinuation { continuation in producer.performAction(presentationID: "owned-graphics", kind: "exercise-graphics") { continuation.resume(returning: $0) } }
        check(error == nil, "real graphical fence crosses prepare and complete operation replies")
        let after = await snapshot(), rows = host.values
        check(rows.count == 2 && rows[0]["method"] as? String == "prepare" && rows[1]["method"] as? String == "complete",
            "native prepare operation arrives before completion")
        check(rows[0]["contextID"] as? UInt32 == after["contextID"] as? UInt32 && (after["contextID"] as? UInt32 ?? 0) != 0,
            "the actual graphical context ID crosses XPC unchanged")
        check(rows[0]["entryCount"] as? Int == 1 && rows[0]["sameRight"] as? Bool == true,
            "single fence entry transfers one real graphics right with consistent receiver identity")
        let right = rows[0]["right"] as! [String: Any]
        check(right["code"] as? Int32 == 0 && right["type"] as? UInt32 == (UInt32(1) << (UInt32(MACH_PORT_RIGHT_SEND) + 16)),
            "receiver owns valid Mach send references to the graphical fence")
        check(after["setFenceApplied"] as? Bool == true && after["completions"] as? Int == 1,
            "producer applies its real fence after prepare and before completing the fixture")
        check(rows.allSatisfy { $0["pid"] as? Int32 == getpid() } && after["pid"] as? Int32 == pid,
            "both graphics trace endpoints confirm separate-process execution")
        try! JSONSerialization.data(withJSONObject: rows, options: .sortedKeys).write(to: directory.appendingPathComponent("host-graphics-trace.json"))
        try! JSONSerialization.data(withJSONObject: after, options: .sortedKeys).write(to: directory.appendingPathComponent("producer-graphics-state.json"))
        try! JSONSerialization.data(withJSONObject: ["status": "passed", "checks": checks, "hostPID": getpid(), "producerPID": pid,
            "actualGraphicsContextCreated": true, "actualGraphicsFenceTransferred": true, "remoteHostPeerUsed": false,
            "remoteHostRenderingExercised": false], options: .sortedKeys).write(to: directory.appendingPathComponent("result.json"))
    }
}
