import AppKit
import Foundation

private final class AppSnapshotWallClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: TimeInterval = 100, sleepers = 0
    var now: Date { lock.withLock { Date(timeIntervalSince1970: value) } }
    func advance() { lock.withLock { value += 10 } }
    var activeSleepers: Int { lock.withLock { sleepers } }
    func sleep(_ duration: Duration) async throws {
        lock.withLock { sleepers += 1 }; defer { lock.withLock { sleepers -= 1 } }
        try await Task.sleep(for: duration)
    }
}
private actor AppSnapshotCaptureGate {
    private var entered = false, opened = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = [], waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true; for item in enteredWaiters { item.resume() }; enteredWaiters = []
        if opened { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async { if entered { return }; await withCheckedContinuation { enteredWaiters.append($0) } }
    func release() { opened = true; waiter?.resume(); waiter = nil }
}
private enum NativeAppSnapshotCheckFailure: Error { case capture }

@MainActor private final class NativeAppSnapshotFixture {
    let wall = AppSnapshotWallClock(), base: LifecycleFixture
    var trace: [String] = [], pending: [ControllerNativeInstanceBindings.Manager.Instance] = []
    var block: URL?, failCapture = false, malformedImage = false, withImage = false
    var disableValues: [Bool] = [], captureGate: AppSnapshotCaptureGate?
    var image: ControllerTemporaryImage?
    let directory: URL
    init(directory: URL) {
        self.directory = directory
        let wall = wall
        let bindings = ControllerNativeInstanceBindings(input: .init(ignoredSourcePID: getpid(),
            events: { AsyncStream { $0.finish() } }, resolveTarget: { _ in preconditionFailure("No input") }),
            now: { wall.now }, sleep: { try await wall.sleep($0) })
        base = LifecycleFixture(bindings: bindings)
    }
    var environment: ControllerNativeAppSnapshotRequestEnvironment {
        .init(capture: { controller, disable in
            self.trace.append("capture"); self.disableValues.append(disable)
            if let gate = self.captureGate { await gate.wait() }
            if self.failCapture { throw NativeAppSnapshotCheckFailure.capture }
            let initial = try NativeSecondaryScrollDataAppSnapshotBindingChecks.result(self.base.data)
            var attachment = initial.attachment
            if self.withImage || self.malformedImage {
                let url = self.directory.appendingPathComponent("owned wire %.png")
                try Data("owned typed-reply fixture, not a screen capture".utf8).write(to: url)
                let file = ControllerTemporaryImage(adopting: url, cleanup: { try FileManager.default.removeItem(at: $0) }, failed: { _ in })
                self.image = file; controller.owner.appSnapshotImageFiles.insert(file)
                attachment = .init(text: "owned state 👋\nline two", screenshot: file,
                    mimeType: self.malformedImage ? nil : "application/x-owned-image", screenshotNeededForContext: true,
                    accessibilityInspectorPayload: nil)
            }
            //The real native capture commits its tree before URL policy. Keep
            //that same observable owner state through a later policy error.
            controller.owner.lastAXTree = initial.axTree
            return .init(attachment: attachment, imageSize: nil, axTree: initial.axTree)
        }, blockedURL: { controller, capture in
            self.trace.append("policy"); precondition(capture.axTree === controller.owner.lastAXTree)
            return self.block
        }, scheduleFinished: { self.trace.append("schedule"); self.pending.append($0) },
            instructions: { app in self.trace.append("instructions"); precondition(app.bundleIdentifier == self.base.target.bundleIdentifier); return "owned instructions" })
    }
    func requery(_ disable: Bool = false) async throws -> ControllerIPCAppSnapshotResult {
        try await base.lifecycle.getAppSnapshot(base.target, requestedIdentifier: "owned state alias", sender: nil,
            disableAXDiffing: disable, requestEnvironment: environment)
    }
    func interrupt() { base.bindings.manager.registerUserInterruptedIntervention(for: base.target.identifier); wall.advance() }
    func finish() async {
        base.bindings.manager.clearUserInterruptedIntervention(for: base.target.identifier)
        await base.finish(); image = nil
        for _ in 0..<100 where wall.activeSleepers != 0 { try? await Task.sleep(for: .milliseconds(1)) }
    }
}

@MainActor enum NativeAppSnapshotRequestChecks {
    static func run(output: URL, directory: URL) async throws -> Int32 {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name": name, "passed": passed]) }
        for disable in [false, true] {
            let f = NativeAppSnapshotFixture(directory: directory.appendingPathComponent(disable ? "true" : "false"))
            try FileManager.default.createDirectory(at: f.directory, withIntermediateDirectories: true)
            let first = try await f.requery(disable)
            let instance = f.base.bindings.manager.instance(for: f.base.target.identifier)!
            check("native state request prepares launch and activates canonical owner disable=\(disable)", instance.controller.owner.isActive && f.base.trace.values.prefix(2) == ["launch", "construct"])
            check("native request retains per-instance capture-policy-format sequence disable=\(disable)", f.trace == ["capture", "policy", "schedule", "instructions"] && f.disableValues == [disable])
            check("native reply returns exact app identity and captured text disable=\(disable)", first.app.pid == getpid() && first.app.bundleIdentifier == f.base.target.bundleIdentifier && first.app.appPath == f.base.target.url.path(percentEncoded: false) && first.appSnapshot.text == "owned capture result" && first.appSnapshot.screenshot == nil)
            check("native successful requery schedules completion without waiting for cursor disable=\(disable)", f.pending.count == 1 && f.pending[0] === instance && instance.controller.owner.virtualCursor == nil)
            f.interrupt()
            check("native fixture publishes expired interruption requiring state requery disable=\(disable)", f.base.bindings.manager.userInterruptedIntervention(for: f.base.target.identifier)?.requiresRequery == true)
            _ = try await f.requery(disable)
            check("native successful state capture clears the current expired interruption disable=\(disable)", f.base.bindings.manager.interventionReason(for: f.base.target.identifier) == nil && f.base.configurations.count == 1)
            let data = try JSONEncoder().encode(first)
            let normalized = try SocketResponseBody.normalizeData(data, for: "ComputerUseIPCAppGetAppSnapshotRequest") as! [String: Any]
            check("actual socket response decoder accepts typed native reply disable=\(disable)", normalized["appSpecificInstructions"] as? String == "owned instructions" && (normalized["appSnapshot"] as? [String: Any])?["screenshot"] == nil)
            check("typed reply roundtrips without inventing active-state field disable=\(disable)", try JSONDecoder().decode(ControllerIPCAppSnapshotResult.self, from: data) == first && normalized["active"] == nil)
            await f.finish(); check("native request fixture cancels its observer timer disable=\(disable)", f.wall.activeSleepers == 0)
        }
        for failsPolicy in [false, true] {
            let f = NativeAppSnapshotFixture(directory: directory)
            _ = try await f.requery(); f.interrupt(); f.trace = []; f.pending = []
            f.failCapture = !failsPolicy
            let blocked = URL(string: "https://EXAMPLE.invalid/path?q=owned#fragment")!
            if failsPolicy { f.block = blocked }
            var failed = false
            do { _ = try await f.requery() }
            catch ControllerAppSnapshotRequestFailure.blockedURL(let url) { failed = failsPolicy && url == blocked }
            catch NativeAppSnapshotCheckFailure.capture { failed = !failsPolicy }
            check("native \(failsPolicy ? "policy" : "capture") failure preserves requery requirement and skips completion", failed && f.base.bindings.manager.userInterruptedIntervention(for: f.base.target.identifier)?.requiresRequery == true && f.pending.isEmpty && !f.trace.contains("instructions"))
            check("native \(failsPolicy ? "policy" : "capture") failure preserves controller and published tree", f.base.bindings.manager.instance(for: f.base.target.identifier)?.controller.owner.lastAXTree != nil && f.base.configurations.count == 1)
            await f.finish()
        }
        do {
            let f = NativeAppSnapshotFixture(directory: directory); f.withImage = true
            let reply = try await f.requery(true), data = try JSONEncoder().encode(reply)
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            check("native screenshot preserves captured MIME instead of filename extension", reply.appSnapshot.screenshot?.mimeType == "application/x-owned-image" && reply.appSnapshot.screenshot?.url.lastPathComponent == "owned wire %.png")
            check("native image wire value preserves Unicode text and percent-encoded file URL", reply.appSnapshot.text == "owned state 👋\nline two" && (object["appSnapshot"] as? [String: Any])?["text"] as? String == reply.appSnapshot.text && reply.appSnapshot.screenshot!.url.absoluteString.contains("%25"))
            let normalized = try SocketResponseBody.normalizeData(data, for: "ComputerUseIPCAppGetAppSnapshotRequest") as! [String: Any]
            check("typed image reply matches actual socket associated response schema", (normalized["appSnapshot"] as? [String: Any])?["screenshot"] is [String: Any] && Set(object.keys) == ["app", "appSnapshot", "appSpecificInstructions"])
            try data.write(to: output.deletingLastPathComponent().appendingPathComponent("native-wire-reply.json"))
            check("native owner retains image while response contains only URL metadata", f.base.bindings.manager.instance(for: f.base.target.identifier)!.controller.owner.appSnapshotImageFiles.count == 1 && FileManager.default.fileExists(atPath: reply.appSnapshot.screenshot!.url.path))
            await f.finish()
        }
        do {
            let f = NativeAppSnapshotFixture(directory: directory); f.malformedImage = true
            var failed = false
            do { _ = try await f.requery() } catch ControllerAppSnapshotRequestFailure.missingScreenshotMIMEType { failed = true }
            check("invalid native screenshot pair fails without guessing MIME after successful requery bookkeeping", failed && f.pending.count == 1 && f.trace.last == "instructions")
            await f.finish()
        }
        do {
            let f = NativeAppSnapshotFixture(directory: directory), gate = AppSnapshotCaptureGate(); f.captureGate = gate
            let first = Task { @MainActor in try await f.requery() }
            await gate.waitUntilEntered()
            let instance = f.base.bindings.manager.instance(for: f.base.target.identifier)!
            var deactivated = false
            let second = Task { @MainActor in
                let reply = try await f.base.lifecycle.modify(f.base.target, requestedIdentifier: "owned alias", sender: nil, deactivate: true)
                deactivated = true; return reply
            }
            for _ in 0..<20 { await Task.yield() }
            check("native state capture and deactivation share the same awaited instance queue", !deactivated && instance.controller.owner.isActive && f.base.bindings.manager.instance(for: f.base.target.identifier) === instance)
            await gate.release(); _ = try await first.value; let stopped = try await second.value
            check("queued deactivation runs only after native state response finishes", deactivated && !stopped.active && f.base.bindings.manager.instance(for: f.base.target.identifier) == nil)
            await f.finish()
        }
        do {
            let f = NativeAppSnapshotFixture(directory: directory); _ = try await f.requery()
            let instance = f.base.bindings.manager.instance(for: f.base.target.identifier)!, previous = instance.controller
            let replacement = try f.base.make(f.base.target, instance.configuration)
            var creations = 0
            let handle = ControllerCursorMonitorWindow(isVisible: { false }, setApplicationReason: { _ in }, retarget: { _ in })
            let creation = ControllerNativeCursorCreationEnvironment(makeCursor: { creations += 1; return ControllerApprovedCursor() },
                window: { _ in handle }, application: { _ in f.base.data.application }, monitor: { _, _, _ in nil })
            ControllerNativeAppSnapshotRequestEnvironment.scheduleFinished(instance, creation: creation)
            instance.controller = replacement
            for _ in 0..<100 where replacement.owner.virtualCursor?.activityState != 1 { try await Task.sleep(for: .milliseconds(1)) }
            check("scheduled finished cursor rereads current controller and uses complete factory", creations == 1 && previous.owner.virtualCursor == nil && replacement.owner.virtualCursor?.activityState == 1 && replacement.owner.virtualCursor?.correspondingApplicationPID == replacement.owner.pid && replacement.owner.virtualCursor?.visibleWindowID == nil)
            replacement.owner.virtualCursor = nil; previous.deactivate(); await f.finish()
        }
        let instructions = ControllerNativeAppSnapshotRequestEnvironment.native.instructions(.init(pid: getpid(), bundleIdentifier: "com.apple.Music", appPath: nil))
        // A packaged app keeps resources in Contents/Resources; a bare build keeps them beside the executable.
        let packagedMusic = Bundle.main.url(forResource: "AppleMusic", withExtension: "md", subdirectory: "AppInstructions")
        let bareBuildMusic = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("Resources/AppInstructions/AppleMusic.md")
        let expectedMusic = try String(contentsOf: packagedMusic ?? bareBuildMusic, encoding: .utf8)
        check("native response instructions load exact packaged app resource", instructions == expectedMusic && !expectedMusic.isEmpty)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "checks": checks,
            "native_manager_queue_request_formatter_and_socket_schema_executed": true,
            "capture_policy_cursor_and_input_effect_providers_intercepted": true,
            "actual_native_capture_focus_mouse_keyboard_cursor_window_network_or_preferences": false,
            "ordinary_request_routes_selected": false,
            "full_goal_complete": false], options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Native appSnapshot request: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
