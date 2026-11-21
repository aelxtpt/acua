import Foundation

private final class Box<T> {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return storage }
    func change(_ body: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; body(&storage) }
}

@main enum CaptureStreamTests {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ value: Bool) { precondition(value, name); passed += 1; print("PASS \(name)") }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name) } catch { check(name, true) }
        }
        func storeError(_ name: String, _ expected: AppCaptureStore<Int>.StoreError, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name) }
            catch let error as AppCaptureStore<Int>.StoreError { check(name, error == expected) }
            catch { preconditionFailure("Unexpected error \(error)") }
        }
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        func start(_ text: String) throws -> AppCaptureWire.Start { try decoder.decode(AppCaptureWire.Start.self, from: Data(text.utf8)) }
        let initial = try start(#"{"app":"Test.app","requestId":"r"}"#)
        check("missing permission ID falls back to capture request ID", initial.permissionRequestID == "r")
        check("missing version defaults to initial contract", initial.version == .initial && !initial.version.supportsReliableFinalFrame)
        check("missing animation is accepted", initial.animationTarget == nil)
        let explicit = try start(#"{"app":"Test.app","requestId":"r","permissionRequestId":"permission","version":2}"#)
        check("explicit permission request stays independent", explicit.permissionRequestID == "permission")
        let canonical = try start(#"{"app":"Test.app","requestId":"r","permissionRequestId":"permission","version":2}"#)
        check("canonical capture ID spellings preserve the explicit permission key", canonical == explicit)
        let encodedStart = try JSONSerialization.jsonObject(with: encoder.encode(canonical)) as! [String: Any]
        check("Start encodes only the canonical request ID keys", encodedStart["requestId"] as? String == "r" &&
              encodedStart["permissionRequestId"] as? String == "permission" &&
              encodedStart["requestID"] == nil && encodedStart["permissionRequestID"] == nil)
        let mixed = try start(#"{"app":"Test.app","requestId":"native","requestID":"legacy","permissionRequestId":null,"permissionRequestID":"ignored"}"#)
        check("native spelling takes precedence, including an explicit null permission ID",
              mixed.requestID == "native" && mixed.permissionRequestID == "native")
        rejects("invalid native request ID is not replaced by the legacy alias") {
            _ = try start(#"{"app":"Test.app","requestId":false,"requestID":"legacy"}"#)
        }
        rejects("Start requires the requestId spelling") {
            _ = try start(#"{"app":"Test.app","requestID":"legacy"}"#)
        }
        rejects("Next requires the requestId spelling") {
            _ = try decoder.decode(AppCaptureWire.Next.self, from: Data(#"{"requestID":"legacy"}"#.utf8))
        }
        let ignoredPermission = try start(#"{"app":"Test.app","requestId":"native","permissionRequestID":"ignored"}"#)
        check("unsupported permissionRequestID is ignored", ignoredPermission.permissionRequestID == "native")
        let next = try decoder.decode(AppCaptureWire.Next.self, from: Data(#"{"requestId":"r"}"#.utf8))
        let wire = try JSONSerialization.jsonObject(with: encoder.encode(next)) as! [String: String]
        check("Next emits only the requestId key", wire == ["requestId": "r"])
        check("version two enables reliable final frame", explicit.version.supportsReliableFinalFrame)
        for version in [-1, 0, 1, 2, 3, Int.max] {
            let value = try start("{\"app\":\"Test.app\",\"requestId\":\"r\",\"version\":\(version)}")
            check("future/raw capture version \(version) round trips", value.version.rawValue == version && value.version.supportsReliableFinalFrame == (version > 1))
        }
        for bad in [#"{"app":"Test.app"}"#, #"{"app":true,"requestId":"r"}"#, #"{"app":"Test.app","requestId":2}"#, #"{"app":"Test.app","requestId":"r","version":true}"#, #"{"app":"Test.app","requestId":"r","version":1.5}"#, #"{"app":"Test.app","requestId":"r","permissionRequestId":2}"#] {
            rejects("required capture IDs and integer version reject invalid JSON types") { _ = try start(bad) }
        }
        let malformedAnimation = try start(#"{"app":"Test.app","requestId":"r","animationTarget":{"destinationFrame":"invalid"}}"#)
        check("tolerant animation decode does not mask other fields", malformedAnimation.animationTarget == nil && malformedAnimation.requestID == "r")
        let full = try start(#"{"app":"Test.app","requestId":"r","animationTarget":{"destinationFrame":{"x":-10,"y":20,"width":300,"height":200},"destinationCornerRadius":12,"destinationBackgroundColor":{"red":10,"green":20,"blue":30},"destinationPrimaryTextColor":{"red":255,"green":255,"blue":255},"presentationStyle":"quick_chat","agentDisplay":{"id":42,"bounds":{"x":0,"y":0,"width":1440,"height":900},"workArea":{"x":0,"y":24,"width":1440,"height":876},"scaleFactor":2}}}"#)
        check("full animation contract decodes RGB integers and quick chat style", full.animationTarget?.destinationBackgroundColor?.blue == 30 && full.animationTarget?.presentationStyle == .quickChat)
        check("display coordinates and backing scale retain their own units", full.animationTarget?.destinationFrame.x == -10 && full.animationTarget?.agentDisplay.scaleFactor == 2)
        var targetJSON = try JSONSerialization.jsonObject(with: encoder.encode(full)) as! [String: Any]
        var target = targetJSON["animationTarget"] as! [String: Any]
        target.removeValue(forKey: "destinationCornerRadius"); target.removeValue(forKey: "destinationBackgroundColor")
        target.removeValue(forKey: "destinationPrimaryTextColor"); target.removeValue(forKey: "presentationStyle")
        targetJSON["animationTarget"] = target
        let minimalTarget = try decoder.decode(AppCaptureWire.Start.self, from: JSONSerialization.data(withJSONObject: targetJSON))
        check("missing optional animation styling keeps required target", minimalTarget.animationTarget != nil && minimalTarget.animationTarget?.presentationStyle == .standard)
        target["destinationCornerRadius"] = "bad"; target["destinationBackgroundColor"] = ["red": "bad"]
        target["destinationPrimaryTextColor"] = false; target["presentationStyle"] = "future_style"
        targetJSON["animationTarget"] = target
        let tolerant = try decoder.decode(AppCaptureWire.Start.self, from: JSONSerialization.data(withJSONObject: targetJSON))
        check("invalid optional styling defaults independently without dropping animation", tolerant.animationTarget != nil && tolerant.animationTarget?.destinationCornerRadius == nil && tolerant.animationTarget?.destinationBackgroundColor == nil && tolerant.animationTarget?.destinationPrimaryTextColor == nil && tolerant.animationTarget?.presentationStyle == .standard)
        target.removeValue(forKey: "agentDisplay"); targetJSON["animationTarget"] = target
        let missingDisplay = try decoder.decode(AppCaptureWire.Start.self, from: JSONSerialization.data(withJSONObject: targetJSON))
        check("missing required display drops animation without rejecting capture", missingDisplay.animationTarget == nil)
        let response = AppCaptureWire.StartResponse(result: .started)
        let responseJSON = try JSONSerialization.jsonObject(with: encoder.encode(response)) as! [String: Any]
        check("started response uses result and omits absent animation fields", responseJSON.count == 1 && responseJSON["result"] as? String == "started")
        let abandoned = AppCaptureWire.StartResponse(result: .permissionsAbandoned, permissionGrantState: .screenRecording)
        let abandonedJSON = try JSONSerialization.jsonObject(with: encoder.encode(abandoned)) as! [String: Any]
        check("permission result and state use snake-case wire values", abandonedJSON["result"] as? String == "appshot_permissions_abandoned" && abandonedJSON["permissionGrantState"] as? String == "screen_recording_granted")
        let app = IPCApp(pid: 100, bundleIdentifier: "test.app", appPath: "/Applications/Test.app")
        let url = URL(fileURLWithPath: "/tmp/capture-image.jpg")
        let update = AppCaptureWire.Update(type: .screenshot, app: app, screenshot: .init(url: url, mimeType: "image/jpeg"))
        let updateJSON = try JSONSerialization.jsonObject(with: encoder.encode(update)) as! [String: Any]
        check("screenshot update uses URL and mimeType without invented geometry fields", (updateJSON["screenshot"] as? [String: Any])?.count == 2 && updateJSON["text"] == nil)
        check("capture update preserves full app metadata", try decoder.decode(AppCaptureWire.Update.self, from: encoder.encode(update)) == update)
        check("failure reason uses the snake-case wire spelling", String(data: try encoder.encode(AppCaptureWire.FailureReason.blockedByPolicy), encoding: .utf8) == #""blocked_by_policy""#)
        let stages = AppCaptureStore<AppCaptureWire.Update>()
        let stageToken = try stages.begin(requestID: "stages", cancel: {})
        for type in [AppCaptureWire.UpdateType.metadata, .axText, .screenshot, .completed] {
            try stages.publish(.init(type: type, app: app), token: stageToken, terminal: type == .completed)
        }
        var sequence: [AppCaptureWire.UpdateType] = []
        for _ in 0..<4 { let delivery = try stages.next(requestID: "stages", check: {}); sequence.append(delivery.value.type); try delivery.commit() }
        check("one capture delivers a finite FIFO sequence ending at completion", sequence == [.metadata, .axText, .screenshot, .completed] && stages.count == 0)

        let cancelled = Box(0), discarded = Box<[Int]>([])
        let store = AppCaptureStore<Int>(discard: { value in discarded.change { $0.append(value) } })
        let token = try store.begin(requestID: "r", cancel: { cancelled.change { $0 += 1 } })
        try store.publish(10, token: token); try store.publish(20, token: token, terminal: true)
        let first = try store.next(requestID: "r", check: {})
        check("first delivery reserves the oldest stage", first.value == 10 && store.count == 1)
        storeError("second reader cannot steal a reserved delivery", .readerBusy) { _ = try store.next(requestID: "r", check: {}) }
        first.abandon()
        let retry = try store.next(requestID: "r", check: {})
        check("abandoned or unencoded stage remains available", retry.value == 10)
        storeError("abandoned receipt cannot consume a later reader's stage", .readerBusy) { try first.commit() }
        try retry.commit()
        storeError("a receipt can only commit once", .readerBusy) { try retry.commit() }
        let final = try store.next(requestID: "r", check: {})
        check("terminal stage keeps session alive until delivery commits", final.value == 20 && cancelled.value == 0)
        try final.commit()
        check("terminal commit removes capture and cancels producer once", store.count == 0 && cancelled.value == 1)
        check("consumed values are transferred rather than discarded", discarded.value.isEmpty)
        storeError("reading after completion cannot hang forever", .missing) { _ = try store.next(requestID: "r", check: {}) }
        storeError("late producer is rejected after completion", .missing) { try store.publish(30, token: token) }
        check("late update is disposed exactly once", discarded.value == [30])

        let old = try store.begin(requestID: "reuse", cancel: { cancelled.change { $0 += 1 } })
        try store.publish(40, token: old)
        let oldDelivery = try store.next(requestID: "reuse", check: {})
        let fresh = try store.begin(requestID: "reuse", cancel: { cancelled.change { $0 += 1 } })
        check("reusing request ID cancels its old producer", cancelled.value == 2)
        storeError("old delivery cannot commit into reused ID", .replaced) { try oldDelivery.commit() }
        storeError("old producer cannot contaminate reused ID", .replaced) { try store.publish(50, token: old) }
        store.remove(old)
        try store.publish(60, token: fresh)
        let freshDelivery = try store.next(requestID: "reuse", check: {})
        check("removing old generation does not remove new capture", freshDelivery.value == 60)
        try freshDelivery.commit(); store.remove(fresh); store.remove(fresh)
        check("replacement cleanup is exactly once per generation", cancelled.value == 3 && discarded.value.sorted() == [30, 40, 50])

        let defaultCapacity = AppCaptureStore<Int>()
        var defaultTokens: [AppCaptureStore<Int>.Token] = []
        for index in 0..<33 { defaultTokens.append(try defaultCapacity.begin(requestID: "capacity-\(index)", cancel: {})) }
        check("default capture store accepts the 33rd unread request", defaultCapacity.count == 33)
        for value in 0..<17 { try defaultCapacity.publish(value, token: defaultTokens[0]) }
        var defaultValues: [Int] = []
        for _ in 0..<17 {
            let delivery = try defaultCapacity.next(requestID: "capacity-0", check: {})
            defaultValues.append(delivery.value); try delivery.commit()
        }
        check("default update queue preserves FIFO beyond the old16-stage cutoff", defaultValues == Array(0..<17))
        defaultCapacity.removeAll()

        let clock = Box(ContinuousClock.now), expiryCancel = Box(0)
        let limited = AppCaptureStore<Int>(maximumCaptures: 1, maximumStages: 1, lifetime: 5, now: { clock.value })
        let l = try limited.begin(requestID: "limit", cancel: { expiryCancel.change { $0 += 1 } })
        storeError("capture count is bounded without evicting active capture", .full) { _ = try limited.begin(requestID: "other", cancel: {}) }
        try limited.publish(1, token: l)
        storeError("producer queue is bounded", .full) { try limited.publish(2, token: l) }
        clock.change { $0 = $0.advanced(by: .seconds(6)) }; limited.reapExpired(); limited.reapExpired()
        check("unconsumed captures expire and cancel once", limited.count == 0 && expiryCancel.value == 1)
        let t = try limited.begin(requestID: "terminal", cancel: {})
        try limited.publish(3, token: t, terminal: true)
        storeError("producer cannot append behind a terminal stage", .finished) { try limited.publish(4, token: t) }
        limited.removeAll()

        let waitStore = AppCaptureStore<Int>()
        let waiting = try waitStore.begin(requestID: "wait", cancel: {})
        func waitForStage() -> (ready: DispatchSemaphore, gate: DispatchSemaphore, done: DispatchSemaphore,
                                value: Box<Int?>, error: Box<AppCaptureStore<Int>.StoreError?>) {
            let ready = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            let value = Box<Int?>(nil), error = Box<AppCaptureStore<Int>.StoreError?>(nil)
            DispatchQueue.global().async {
                var checkpoints = 0
                do {
                    let delivery = try waitStore.next(requestID: "wait", maximumWait: 2, check: {
                        checkpoints += 1
                        if checkpoints == 2 { ready.signal(); precondition(gate.wait(timeout: .now() + 2) == .success) }
                    })
                    try delivery.commit()
                    value.change { $0 = delivery.value }
                } catch let storeError as AppCaptureStore<Int>.StoreError { error.change { $0 = storeError } }
                catch { preconditionFailure("Unexpected error \(error)") }
                done.signal()
            }
            return (ready, gate, done, value, error)
        }
        let earlier = waitForStage()
        precondition(earlier.ready.wait(timeout: .now() + 2) == .success)
        let latest = waitForStage()
        precondition(latest.ready.wait(timeout: .now() + 2) == .success)
        earlier.gate.signal()
        precondition(earlier.done.wait(timeout: .now() + 2) == .success)
        check("a newer pending reader supersedes the earlier reader", earlier.value.value == nil && earlier.error.value == .readerSuperseded)
        try waitStore.publish(99, token: waiting)
        storeError("publication reserves the update for the pending reader", .readerBusy) { _ = try waitStore.next(requestID: "wait", check: {}) }
        latest.gate.signal()
        precondition(latest.done.wait(timeout: .now() + 2) == .success)
        check("latest pending reader receives the update once", latest.value.value == 99 && latest.error.value == nil)
        storeError("empty capture wait has an independent time bound", .timedOut) { _ = try waitStore.next(requestID: "wait", maximumWait: 0.01, check: {}) }
        rejects("expired request is checked before capture consumption") {
            try RequestRuntime.withRequest(["deadlineUnixMilliseconds": 0]) {
                _ = try waitStore.next(requestID: "wait", check: RequestRuntime.check)
            }
        }
        let checkpointToken = try waitStore.begin(requestID: "checkpoint", cancel: {})
        try waitStore.publish(100, token: checkpointToken)
        let checkpointDelivery = try waitStore.next(requestID: "checkpoint", check: {})
        rejects("cancellation before publication leaves delivery uncommitted") { try checkpointDelivery.commit(check: { throw ServiceError(.unknownError, "cancelled") }) }
        checkpointDelivery.abandon()
        let recovered = try waitStore.next(requestID: "checkpoint", check: {})
        check("stage survives a failed publication checkpoint", recovered.value == 100)
        try recovered.commit(); waitStore.removeAll()

        let reentrant = AppCaptureStore<Int>()
        let reentrantCount = Box(0)
        let reentrantToken = try reentrant.begin(requestID: "cleanup", cancel: { reentrantCount.change { $0 = reentrant.count + 1 } })
        reentrant.remove(reentrantToken)
        check("producer cleanup can reenter the store without a lock cycle", reentrantCount.value == 1)

        let cancellationStore = AppCaptureStore<Int>()
        let cancellationToken = try cancellationStore.begin(requestID: "cancel", cancel: {})
        let cancelledFlag = Box(false), cancelReady = DispatchSemaphore(value: 0), cancelDone = DispatchSemaphore(value: 0)
        let cancellationObserved = Box(false)
        DispatchQueue.global().async {
            var checkpoints = 0
            do {
                _ = try cancellationStore.next(requestID: "cancel", maximumWait: 2, check: {
                    checkpoints += 1
                    if checkpoints == 2 { cancelReady.signal() }
                    if cancelledFlag.value { throw ServiceError(.unknownError, "Cancelled waiting reader") }
                })
            } catch let e as ServiceError { cancellationObserved.change { $0 = e.message == "Cancelled waiting reader" } }
            catch {}
            cancelDone.signal()
        }
        precondition(cancelReady.wait(timeout: .now() + 2) == .success)
        cancelledFlag.change { $0 = true }
        precondition(cancelDone.wait(timeout: .now() + 2) == .success)
        check("request cancellation interrupts an already waiting reader", cancellationObserved.value && cancellationStore.count == 1)
        try cancellationStore.publish(111, token: cancellationToken)
        let afterCancellation = try cancellationStore.next(requestID: "cancel", check: {})
        check("cancelled waiter releases reader slot for later polling", afterCancellation.value == 111)
        try afterCancellation.commit(); cancellationStore.removeAll()

        let replacementStore = AppCaptureStore<Int>()
        _ = try replacementStore.begin(requestID: "replace-waiter", cancel: {})
        let replaceReady = DispatchSemaphore(value: 0), replaceDone = DispatchSemaphore(value: 0)
        let replacementObserved = Box(false)
        DispatchQueue.global().async {
            var checkpoints = 0
            do {
                _ = try replacementStore.next(requestID: "replace-waiter", maximumWait: 2, check: {
                    checkpoints += 1
                    if checkpoints == 2 { replaceReady.signal() }
                })
            } catch let e as AppCaptureStore<Int>.StoreError { replacementObserved.change { $0 = e == .replaced } }
            catch {}
            replaceDone.signal()
        }
        precondition(replaceReady.wait(timeout: .now() + 2) == .success)
        let replacementToken = try replacementStore.begin(requestID: "replace-waiter", cancel: {})
        try replacementStore.publish(222, token: replacementToken)
        precondition(replaceDone.wait(timeout: .now() + 2) == .success)
        check("replaced pending reader is awakened without reading new generation", replacementObserved.value)
        let replacementDelivery = try replacementStore.next(requestID: "replace-waiter", check: {})
        check("new generation retains its update after old reader exits", replacementDelivery.value == 222)
        try replacementDelivery.commit(); replacementStore.removeAll()

        let deinitCancels = Box(0), deinitDrops = Box(0)
        var disposable: AppCaptureStore<Int>? = AppCaptureStore(discard: { _ in deinitDrops.change { $0 += 1 } })
        let disposableToken = try disposable!.begin(requestID: "dispose", cancel: { deinitCancels.change { $0 += 1 } })
        try disposable!.publish(333, token: disposableToken)
        let orphanedDelivery = try disposable!.next(requestID: "dispose", check: {})
        disposable = nil
        check("store teardown releases a reserved uncommitted update", deinitCancels.value == 1 && deinitDrops.value == 1)
        storeError("orphaned delivery cannot report a successful publication", .missing) { try orphanedDelivery.commit() }

        let retainedClock = Box(ContinuousClock.now), retainedCancel = Box(0)
        let retained = AppCaptureStore<Int>(now: { retainedClock.value })
        let retainedToken = try retained.begin(requestID: "retained", cancel: { retainedCancel.change { $0 += 1 } })
        retainedClock.change { $0 = $0.advanced(by: .seconds(1000)) }; retained.reapExpired()
        check("default active capture is not expired before a terminal stage", retained.count == 1)
        try retained.publish(444, token: retainedToken, terminal: true)
        retainedClock.change { $0 = $0.advanced(by: .milliseconds(29_900)) }; retained.reapExpired()
        check("unread terminal stage is retained for thirty seconds", retained.count == 1)
        retainedClock.change { $0 = $0.advanced(by: .milliseconds(100)) }; retained.reapExpired()
        check("terminal retention starts when terminal is published", retained.count == 0 && retainedCancel.value == 1)
        let expirySignal = DispatchSemaphore(value: 0)
        let automatic = AppCaptureStore<Int>(lifetime: 5, terminalRetention: 0.02)
        let automaticToken = try automatic.begin(requestID: "auto", cancel: { expirySignal.signal() })
        try automatic.publish(555, token: automaticToken, terminal: true)
        precondition(expirySignal.wait(timeout: .now() + 2) == .success)
        check("terminal cleanup runs even when no client polls again", automatic.count == 0)

        let scheduledStart = ContinuousClock.now.advanced(by: .milliseconds(250))
        let scheduledSignal = DispatchSemaphore(value: 0)
        let scheduled = AppCaptureStore<Int>(terminalRetention: 0.02, now: { scheduledStart })
        let scheduledToken = try scheduled.begin(requestID: "scheduled", cancel: { scheduledSignal.signal() })
        try scheduled.publish(666, token: scheduledToken, terminal: true)
        check("timer waits for the absolute continuous deadline",
              scheduledSignal.wait(timeout: .now() + 0.08) == .timedOut)
        precondition(scheduledSignal.wait(timeout: .now() + 2) == .success)
        check("timer removes capture at the deadline without a polling request", scheduled.count == 0)

        for iteration in 0..<300 {
            let cancels = Box(0), drops = Box(0), commits = Box(0)
            let racing = AppCaptureStore<Int>(discard: { _ in drops.change { $0 += 1 } })
            let token = try racing.begin(requestID: "race", cancel: { cancels.change { $0 += 1 } })
            try racing.publish(iteration, token: token, terminal: true)
            let delivery = try racing.next(requestID: "race", check: {})
            let group = DispatchGroup()
            group.enter(); DispatchQueue.global().async { do { try delivery.commit(); commits.change { $0 += 1 } } catch {} ; group.leave() }
            group.enter(); DispatchQueue.global().async { racing.remove(token); group.leave() }
            precondition(group.wait(timeout: .now() + 2) == .success)
            precondition(cancels.value == 1 && drops.value + commits.value == 1 && racing.count == 0, "Resource ownership race \(iteration)")
        }
        check("300 terminal-delivery/removal races cancel once and transfer or discard once", true)
        print("\(passed) capture protocol/store checks passed; native producer, permissions and animation integration remain pending")
    }
}
