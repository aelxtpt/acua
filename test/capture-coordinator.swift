import Foundation
import CoreGraphics

private final class Locked<Value> {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return storage }
    func change(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&storage) }
}

@main enum CaptureCoordinatorTests {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ value: Bool) { precondition(value, name); passed += 1; print("PASS \(name)") }
        func rejects(_ name: String, _ code: CUErrorCode, _ body: () throws -> Void) {
            do { try body(); preconditionFailure(name) }
            catch let e as ServiceError { check(name, e.code == code) }
            catch { preconditionFailure("Unexpected error \(error)") }
        }
        func bounded<T>(_ body: () throws -> T) throws -> T {
            try RequestRuntime.withRequest(["deadlineUnixMilliseconds": (Date().timeIntervalSince1970 + 2) * 1000], body: body)
        }
        func next(_ coordinator: AppCaptureCoordinator, _ id: String) throws -> JSON {
            try bounded { try coordinator.next(["requestId": id]) }
        }
        let app = IPCApp(pid: 123, bundleIdentifier: "fixture.app", appPath: "/tmp/Fixture.app")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cua-capture-coordinator-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let file = temp.appendingPathComponent("fixture.jpg")
        try Data([0xff, 0xd8, 0xff]).write(to: file)
        let cleanups = Locked(0), entered = DispatchSemaphore(value: 0), gate = DispatchSemaphore(value: 0)
        let coordinator = AppCaptureCoordinator { request in
            if request.app == "abandoned" { return .abandoned(.accessibility) }
            if request.app == "pending" { throw ServiceError(.permissionsPending, "Pending fixture permission") }
            return .ready(.init(app: app, run: { emit in
                entered.signal(); precondition(gate.wait(timeout: .now() + 2) == .success)
                try emit.text("Fixture AX content")
                let lease = CaptureFileLease(url: file, remove: { try? FileManager.default.removeItem(at: $0) })
                try emit.screenshot(lease)
                if request.version.supportsReliableFinalFrame { try emit.finalFrame(nil) }
            }, cancel: { cleanups.change { $0 += 1 } }))
        }
        let response = try coordinator.start(["app": "fixture", "requestId": "basic", "version": 2])
        check("Start returns before native provider completes", response["result"] as? String == "started")
        precondition(entered.wait(timeout: .now() + 2) == .success)
        let metadata = try next(coordinator, "basic")
        check("metadata can be consumed before content is ready", metadata["type"] as? String == "metadata")
        check("stage preserves app PID/bundle/path", (metadata["app"] as? JSON)?["appPath"] as? String == app.appPath)
        gate.signal()
        let text = try next(coordinator, "basic"), image = try next(coordinator, "basic")
        check("AX text stage preserves source content", text["text"] as? String == "Fixture AX content")
        check("image stage uses the published file URL", (image["screenshot"] as? JSON)?["url"] as? String == file.absoluteString)
        let final = try next(coordinator, "basic"), completed = try next(coordinator, "basic")
        check("reliable final frame is separate from the image stage", final["type"] as? String == "screenshot" && final["screenshot"] == nil)
        check("completed is delivered after content", completed["type"] as? String == "completed")
        check("terminal delivery cleans producer exactly once", cleanups.value == 1)
        check("a delivered URL survives producer cleanup", FileManager.default.fileExists(atPath: file.path))
        rejects("consumed ID is no longer available", .unknownError) { _ = try next(coordinator, "basic") }
        let abandoned = try coordinator.start(["app": "abandoned", "requestId": "abandoned"])
        check("abandonment carries actual partial permission state", abandoned["result"] as? String == "appshot_permissions_abandoned" && abandoned["permissionGrantState"] as? String == "accessibility_granted")
        rejects("abandoned request does not create a capture queue", .unknownError) { _ = try next(coordinator, "abandoned") }
        rejects("pending permission never becomes invented abandonment", .permissionsPending) { _ = try coordinator.start(["app": "pending", "requestId": "pending"]) }
        rejects("missing Start request ID is a wire-data error", .couldNotGetRequestData) { _ = try coordinator.start(["app": "fixture"]) }
        rejects("non-string Next request ID is a wire-data error", .couldNotGetRequestData) { _ = try coordinator.next(["requestId": true]) }

        var cache = AppshotPermissionCache()
        cache.recordDismissal(ids: ["permission-a", "permission-b"], state: .screenRecording)
        cache.recordDismissal(ids: ["granted"], state: .both)
        check("one permission-panel dismissal preserves the state of every waiting permission ID",
              cache["permission-a"] == .screenRecording && cache["permission-b"] == .screenRecording)
        check("fully granted and unrelated permission IDs have no dismissal record",
              cache["granted"] == nil && cache["another-id"] == nil)
        var preparations = 0
        var settingsVisits = AppshotPermissionSettingsVisits()
        check("permission buttons target distinct privacy panes",
              AppshotPermissionSettingsVisits.Permission.accessibility.settingsURL?.absoluteString == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility" &&
              AppshotPermissionSettingsVisits.Permission.screenRecording.settingsURL?.absoluteString == "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture")
        let firstVisit = settingsVisits.begin(.accessibility)!
        check("only one Settings visit can open across both permissions",
              settingsVisits.begin(.accessibility) == nil && settingsVisits.begin(.screenRecording) == nil)
        settingsVisits.end()
        let replacementVisit = settingsVisits.begin(.accessibility)!
        settingsVisits.failedToOpen(.accessibility, id: firstVisit)
        check("a delayed launch failure or callback cannot affect a later visit for the same permission",
              !settingsVisits.isCurrent(.accessibility, id: firstVisit) && settingsVisits.isCurrent(.accessibility, id: replacementVisit))
        settingsVisits.granted(.screenRecording)
        check("granting a different permission leaves the current visit active", !settingsVisits.isEmpty)
        settingsVisits.failedToOpen(.accessibility, id: replacementVisit)
        check("a launch failure releases the visit so the other pane can open", settingsVisits.begin(.screenRecording) != nil)
        settingsVisits.granted(.screenRecording)
        check("a grant ends the last visit without waiting for app activation", settingsVisits.isEmpty)
        _ = settingsVisits.begin(.accessibility)
        settingsVisits.end()
        check("returning to or closing the panel clears the visit", settingsVisits.isEmpty)

        let settingsBounds = CGRect(x: -900, y: -140, width: 700, height: 470)
        let accessorySize = CGSize(width: 285, height: 128)
        let settingsFrame = AppshotPermissionAccessoryLayout.settingsFrame(settingsBounds, primaryScreenHeight: 900)
        check("the Settings frame converts on a secondary display with negative coordinates",
              settingsFrame == CGRect(x: -900, y: 570, width: 700, height: 470))
        check("the accessory uses the 10-point bottom and right insets",
              settingsFrame.map { AppshotPermissionAccessoryLayout.accessoryFrame(in: $0, size: accessorySize) } ==
              CGRect(x: -495, y: 580, width: 285, height: 128))
        check("small Settings dialogs and a missing primary screen cannot anchor the accessory",
              AppshotPermissionAccessoryLayout.settingsFrame(CGRect(x: 0, y: 0, width: 600, height: 600), primaryScreenHeight: 900) == nil &&
              AppshotPermissionAccessoryLayout.settingsFrame(settingsBounds, primaryScreenHeight: 0) == nil)
        check("the accessory can rise to the audio heading without changing its horizontal position",
              settingsFrame.map { AppshotPermissionAccessoryLayout.accessoryFrame(in: $0, size: accessorySize, audioHeadingOffset: 250) } ==
              CGRect(x: -495, y: 672, width: 285, height: 128))
        check("a lower or nonfinite heading keeps the usual bottom inset",
              [400.0, CGFloat.nan].allSatisfy { offset in
                  settingsFrame.map { AppshotPermissionAccessoryLayout.accessoryFrame(in: $0, size: accessorySize, audioHeadingOffset: offset) } ==
                  CGRect(x: -495, y: 580, width: 285, height: 128)
              })
        let roles = ["AXHeading", "AXStaticText", "AXButton", "AXHeading", "AXStaticText", "AXStaticText", "AXHeading"]
        check("the third matching direct child anchors the audio heading on each OS",
              AppshotPermissionAccessoryLayout.audioHeading(in: Array(roles.indices), role: "AXStaticText", readRole: { roles[$0] }) == 5 &&
              AppshotPermissionAccessoryLayout.audioHeading(in: Array(roles.indices), role: "AXHeading", readRole: { roles[$0] }) == 6 &&
              AppshotPermissionAccessoryLayout.audioHeading(in: Array(roles.indices), role: "AXButton", readRole: { roles[$0] }) == nil)
        var tracking = AppshotPermissionAccessoryTracking()
        check("the accessory waits for the first Settings window",
              tracking.update(windowExists: false, active: true, terminated: false) == .hide)
        check("the first accessory can animate before Settings becomes active",
              tracking.update(windowExists: true, active: false, terminated: false) == .show && tracking.didPresent())
        check("after presenting, the accessory follows Settings activity without taking focus again",
              !tracking.didPresent() && tracking.update(windowExists: true, active: false, terminated: false) == .hide &&
              tracking.update(windowExists: true, active: true, terminated: false) == .show)
        check("unavailable window data does not end the visit, but confirmed window loss does",
              tracking.update(windowExists: nil, active: true, terminated: false) == .hide &&
              tracking.update(windowExists: false, active: false, terminated: false) == .returnToPermissions)
        var unlaunched = AppshotPermissionAccessoryTracking()
        check("Settings termination ends a visit even before its window opens",
              unlaunched.update(windowExists: nil, active: false, terminated: true) == .returnToPermissions)
        let observingSince = ContinuousClock.now
        var unopened = AppshotPermissionAccessoryTracking(startedAt: observingSince)
        check("the Settings visit returns to permissions if a window is still missing after five seconds",
              unopened.update(windowExists: false, active: false, terminated: false, at: observingSince + .milliseconds(4999)) == .hide &&
              unopened.update(windowExists: nil, active: false, terminated: false, at: observingSince + .seconds(5)) == .returnToPermissions)
        check("early activation only recovers an existing Settings window that is not already visible",
              !AppshotPermissionAccessoryTracking.needsEarlyActivation(hasWindows: false, hasVisibleMainWindow: false) &&
              AppshotPermissionAccessoryTracking.needsEarlyActivation(hasWindows: true, hasVisibleMainWindow: false) &&
              !AppshotPermissionAccessoryTracking.needsEarlyActivation(hasWindows: true, hasVisibleMainWindow: true))

        let dropTime = ContinuousClock.now
        var grantCheck = AppshotSettingsGrantCheck()
        check("the grant timeout does not start until the user drops the app",
              grantCheck.update(at: dropTime + .seconds(120), authorized: false, dialogsDismissed: false) == .wait)
        grantCheck.dropped(at: dropTime)
        grantCheck.dropped(at: dropTime + .seconds(30))
        check("repeated drops cannot extend the 120-second grant deadline",
              grantCheck.update(at: dropTime + .milliseconds(119_999), authorized: false, dialogsDismissed: true) == .wait &&
              grantCheck.update(at: dropTime + .seconds(120), authorized: false, dialogsDismissed: false) == .finish)
        var manualGrant = AppshotSettingsGrantCheck()
        check("a permission granted in Settings without a drop starts dialog verification",
              manualGrant.update(at: dropTime, authorized: true, dialogsDismissed: false) == .validated)
        check("dialog verification waits half a second before checking even when the dialogs are already gone",
              manualGrant.update(at: dropTime + .milliseconds(499), authorized: true, dialogsDismissed: true) == .wait &&
              manualGrant.update(at: dropTime + .milliseconds(500), authorized: true, dialogsDismissed: true) == .finish)
        var slowGrant = AppshotSettingsGrantCheck()
        slowGrant.dropped(at: dropTime)
        let grantedAt = dropTime + .seconds(100)
        check("a delayed grant starts its own window for Settings dialogs",
              slowGrant.update(at: grantedAt, authorized: true, dialogsDismissed: false) == .validated &&
              slowGrant.update(at: grantedAt + .seconds(120), authorized: true, dialogsDismissed: false) == .wait &&
              slowGrant.update(at: grantedAt + .milliseconds(120_500), authorized: true, dialogsDismissed: false) == .finish)

        let sourceRow = CGRect(x: 0, y: 0, width: 100, height: 60)
        let targetAccessory = CGRect(x: 200, y: 100, width: 200, height: 100)
        check("the permission transition starts and ends at its original and destination frames",
              AppshotPermissionTransitionGeometry.frame(from: sourceRow, to: targetAccessory, progress: 0) == sourceRow &&
              AppshotPermissionTransitionGeometry.frame(from: sourceRow, to: targetAccessory, progress: 1) == targetAccessory)
        check("the permission transition interpolates size and follows the vertical arc",
              AppshotPermissionTransitionGeometry.frame(from: sourceRow, to: targetAccessory, progress: 0.5) ==
              CGRect(x: 100, y: 160, width: 150, height: 80))
        check("the Back transition traverses the same curve with the endpoints exchanged",
              [0, 0.25, 0.5, 0.75, 1].allSatisfy { progress in
                  AppshotPermissionTransitionGeometry.frame(from: targetAccessory, to: sourceRow, progress: progress) ==
                  AppshotPermissionTransitionGeometry.frame(from: sourceRow, to: targetAccessory, progress: 1 - progress)
              })
        check("the permission spring predicts display time and finishes on convergence",MainActor.assumeIsolated {
            let animation=SystemSettingsSpringAnimation();var samples=[(Double,Bool)]()
            for i in 0...60 {
                let time=Double(i)/30
                animation.performTick(.init(timestamp:time,duration:1.0/60,targetTimestamp:time+1.0/60))
                samples.append((animation.value,animation.state == .finished))
            }
            return samples[0].0 == 0.007546663498336072 && !samples[0].1 && samples.firstIndex(where:{$0.1}) == 32 && samples[32].0 == 1
        })
        typealias TransitionAppearance = AppshotPermissionTransitionGeometry.Appearance
        let startLook = TransitionAppearance(progress: -0.1)
        let endLook = TransitionAppearance(progress: 1.1)
        check("the permission images and blur clamp at the transition endpoints",
              startLook.sourceOpacity == 1 && startLook.sourceBlur == 0 && startLook.targetOpacity == 0 && startLook.targetBlur == 12 &&
              endLook.sourceOpacity == 0 && endLook.sourceBlur == 12 && endLook.targetOpacity == 1 && endLook.targetBlur == 0)
        let midwayLook = TransitionAppearance(progress: 0.25)
        check("the permission images crossfade while their blur changes in opposite directions",
              midwayLook.sourceOpacity == 0.75 && midwayLook.targetOpacity == 0.25 &&
              midwayLook.sourceBlur == 3 && midwayLook.targetBlur == 9)
        check("the destination shadow and half-point stroke fade in over the transition",
              startLook.destinationShadowOpacity == 0 && endLook.destinationShadowOpacity == 1 &&
              midwayLook.destinationShadowOpacity == 0.25 && startLook.strokeOpacity == 0 &&
              endLook.strokeOpacity == 0.15 && midwayLook.strokeOpacity == 0.0375)

        var waiters = AppshotPermissionWaiters<String>()
        var timeoutCache = AppshotPermissionCache()
        let presented = ContinuousClock.now
        let first = UUID(), second = UUID(), canceled = UUID()
        waiters.insert(first, id: "first", reply: "reply-a", at: presented)
        waiters.insert(second, id: "second", reply: "reply-b", at: presented + .seconds(10))
        waiters.insert(canceled, id: "canceled", reply: "reply-c", at: presented)
        waiters.cancel(canceled)
        check("permission wait stays pending until the 110-second deadline",
              waiters.expire(at: presented + .milliseconds(109_999)).isEmpty)
        check("a shared permission panel uses an independent deadline for each request",
              waiters.expire(at: presented + .seconds(110)) == ["reply-a"])
        check("timeout does not record a dismissal", timeoutCache["first"] == nil)
        check("the later request also expires at its own deadline",
              waiters.expire(at: presented + .seconds(120)) == ["reply-b"])
        check("expired requests keep the panel open and a canceled caller does not register for dismissal",
              !waiters.isEmpty && Set(waiters.dismissalIDs) == ["first", "second"])
        timeoutCache.recordDismissal(ids: waiters.dismissalIDs, state: .accessibility)
        check("closing after a timeout records the permissions for expired requests",
              timeoutCache["first"] == .accessibility && timeoutCache["second"] == .accessibility)
        check("closing clears tracked requests without replying to expired callers again", waiters.drain().isEmpty && waiters.isEmpty)

        let permissionCoordinator = AppCaptureCoordinator { _ in
            preparations += 1
            return .ready(.init(app: app, run: { _ in }))
        }
        let cached = try permissionCoordinator.start(["app": "fixture", "requestId": "new-capture", "permissionRequestId": "permission-a"]) {
            cache[$0.permissionRequestID]
        }
        check("a retry with the same permission ID returns the cached dismissal without preparing a capture",
              cached["permissionGrantState"] as? String == "screen_recording_granted" && preparations == 0)
        rejects("permission-gate abandonment never starts a capture queue", .unknownError) { _ = try next(permissionCoordinator, "new-capture") }
        let admitted = try permissionCoordinator.start(["app": "fixture", "requestId": "fresh-capture"]) { request in
            check("omitted permission ID uses the capture request ID", request.permissionRequestID == "fresh-capture")
            return cache[request.permissionRequestID]
        }
        check("a granted permission gate proceeds into the normal capture queue",
              admitted["result"] as? String == "started" && preparations == 1)
        _ = try next(permissionCoordinator, "fresh-capture")
        _ = try next(permissionCoordinator, "fresh-capture")
        rejects("permission-gate failure does not enter capture preparation", .permissionsPending) {
            _ = try permissionCoordinator.start(["app": "fixture", "requestId": "waiting"]) { _ in
                throw ServiceError(.permissionsPending, "Permission prompt is still pending")
            }
        }
        check("failed permission checks leave previous preparations unchanged", preparations == 1)

        for (kind, expected) in [(AppCaptureCoordinator.CaptureFailure.screenshot, "screenshot_capture_failed"), (.blockedByPolicy, "blocked_by_policy"), (.unknown, "unknown_capture_failed")] {
            let failure = AppCaptureCoordinator { _ in .ready(.init(app: app, run: { _ in throw kind })) }
            _ = try failure.start(["app": "fixture", "requestId": "failure"])
            _ = try next(failure, "failure")
            let failed = try next(failure, "failure")
            check("provider error produces terminal \(expected)", failed["type"] as? String == "failed" && failed["failureReason"] as? String == expected)
            rejects("failed capture cannot yield completed afterward", .unknownError) { _ = try next(failure, "failure") }
        }

        let quick = AppCaptureCoordinator { _ in .ready(.init(app: app, run: { try $0.text("retry") })) }
        _ = try quick.start(["app": "fixture", "requestId": "retry"])
        let calls = Locked(0)
        rejects("cancellation during publication does not report success", .unknownError) {
            _ = try RequestRuntime.withRequest([:], cancelled: {
                calls.change { $0 += 1 }; return calls.value >= 4
            }) { try quick.next(["requestId": "retry"]) }
        }
        let retried = try next(quick, "retry")
        check("uncommitted stage survives cancelled Next", retried["type"] as? String == "metadata")
        _ = try next(quick, "retry"); _ = try next(quick, "retry")

        let oldReady = DispatchSemaphore(value: 0), oldGate = DispatchSemaphore(value: 0), oldDone = DispatchSemaphore(value: 0)
        let prepares = Locked(0), oldCancelled = Locked(0)
        let replacement = AppCaptureCoordinator { _ in
            prepares.change { $0 += 1 }; let generation = prepares.value
            return .ready(.init(app: app, run: { emit in
                if generation == 1 {
                    defer { oldDone.signal() }
                    oldReady.signal(); precondition(oldGate.wait(timeout: .now() + 2) == .success)
                    try emit.text("old content")
                } else { try emit.text("new content") }
            }, cancel: { if generation == 1 { oldCancelled.change { $0 += 1 } } }))
        }
        _ = try replacement.start(["app": "fixture", "requestId": "reuse"])
        precondition(oldReady.wait(timeout: .now() + 2) == .success)
        _ = try replacement.start(["app": "fixture", "requestId": "reuse"])
        oldGate.signal(); precondition(oldDone.wait(timeout: .now() + 2) == .success)
        let replacedMeta = try next(replacement, "reuse"), replacedText = try next(replacement, "reuse"), replacedEnd = try next(replacement, "reuse")
        check("reused ID delivers only the replacement producer", replacedMeta["type"] as? String == "metadata" && replacedText["text"] as? String == "new content" && replacedEnd["type"] as? String == "completed")
        check("replacement cancelled original provider once", oldCancelled.value == 1)

        let cancelledDuringPreparation = Locked(false), discardedPlans = Locked(0)
        let preserve = AppCaptureCoordinator { request in
            if request.app == "cancelled" {
                cancelledDuringPreparation.change { $0 = true }
                return .ready(.init(app: app, run: { _ in preconditionFailure("Cancelled plan started") },
                    cancel: { discardedPlans.change { $0 += 1 } }))
            }
            return .ready(.init(app: app, run: { try $0.text("original content") }))
        }
        _ = try preserve.start(["app": "fixture", "requestId": "preserve"])
        rejects("Start cancelled during preparation rejects the replacement", .unknownError) {
            _ = try RequestRuntime.withRequest([:], cancelled: { cancelledDuringPreparation.value }) {
                try preserve.start(["app": "cancelled", "requestId": "preserve"])
            }
        }
        check("cancelled replacement releases its prepared plan once", discardedPlans.value == 1)
        let preservedMeta = try next(preserve, "preserve")
        let preservedText = try next(preserve, "preserve")
        let preservedEnd = try next(preserve, "preserve")
        check("cancelled replacement preserves the original capture",
              preservedMeta["type"] as? String == "metadata" && preservedText["text"] as? String == "original content" &&
              preservedEnd["type"] as? String == "completed")

        let deadlineEntered = DispatchSemaphore(value: 0), deadlineGate = DispatchSemaphore(value: 0)
        let deadline = AppCaptureCoordinator { _ in .ready(.init(app: app, run: { emit in
            deadlineEntered.signal(); precondition(deadlineGate.wait(timeout: .now() + 2) == .success); try emit.check()
        })) }
        _ = try RequestRuntime.withRequest(["deadlineUnixMilliseconds": (Date().timeIntervalSince1970 + 0.1) * 1000]) {
            try deadline.start(["app": "fixture", "requestId": "deadline"])
        }
        precondition(deadlineEntered.wait(timeout: .now() + 2) == .success)
        Thread.sleep(forTimeInterval: 0.12); deadlineGate.signal()
        _ = try next(deadline, "deadline")
        let timeout = try next(deadline, "deadline")
        check("background producer retains deadline after Start scope ends", timeout["type"] as? String == "failed" && timeout["failureReason"] as? String == "unknown_capture_failed")

        let expiredFile = temp.appendingPathComponent("unclaimed.jpg"), produced = DispatchSemaphore(value: 0)
        try Data([1, 2, 3]).write(to: expiredFile)
        let unclaimed = AppCaptureCoordinator(terminalRetention: 0.03) { _ in .ready(.init(app: app, run: { emit in
            try emit.screenshot(CaptureFileLease(url: expiredFile, remove: { try? FileManager.default.removeItem(at: $0) })); produced.signal()
        })) }
        _ = try unclaimed.start(["app": "fixture", "requestId": "unclaimed"])
        precondition(produced.wait(timeout: .now() + 2) == .success)
        let limit = ProcessInfo.processInfo.systemUptime + 2
        while FileManager.default.fileExists(atPath: expiredFile.path), ProcessInfo.processInfo.systemUptime < limit { Thread.sleep(forTimeInterval: 0.002) }
        check("unclaimed image is deleted by terminal expiration", !FileManager.default.fileExists(atPath: expiredFile.path))
        let normal = Locked(0), cancelled = Locked(0)
        let transport = AppCaptureCoordinator { _ in .ready(.init(app: app, run: { try $0.text("transport") },
            cancel: { cancelled.change { $0 += 1 } }, complete: { normal.change { $0 += 1 } })) }
        _ = try transport.start(["app": "fixture", "requestId": "transport"])
        let unsuccessful = ResponseDelivery()
        let firstReply = try ResponseDelivery.withCurrent(unsuccessful) { try next(transport, "transport") }
        check("encoded reply retains its uncommitted capture stage", firstReply["type"] as? String == "metadata")
        rejects("second reader cannot consume a response still being written", .unknownError) { _ = try next(transport, "transport") }
        unsuccessful.abandon()
        check("failed transport preserves the same capture stage for retry", try next(transport, "transport")["type"] as? String == "metadata")
        _ = try next(transport, "transport")
        let completionReply = ResponseDelivery()
        let endReply = try ResponseDelivery.withCurrent(completionReply) { try next(transport, "transport") }
        check("terminal callback waits for actual response publication", endReply["type"] as? String == "completed" && normal.value == 0 && cancelled.value == 0)
        completionReply.abandon()
        check("abandoning terminal response does not finish the transition", normal.value == 0 && cancelled.value == 0)
        let successful = ResponseDelivery()
        _ = try ResponseDelivery.withCurrent(successful) { try next(transport, "transport") }
        successful.commit(); successful.commit(); successful.abandon()
        check("successful terminal write uses completion instead of cancellation exactly once", normal.value == 1 && cancelled.value == 0)
        rejects("successful terminal write removes the capture", .unknownError) { _ = try next(transport, "transport") }

        let finalFile = temp.appendingPathComponent("transition.png")
        try Data([1, 2, 3]).write(to: finalFile)
        let frames = AppCaptureCoordinator { _ in .ready(.init(app: app, run: { emit in
            let lease = CaptureFileLease(url: finalFile, remove: { try? FileManager.default.removeItem(at: $0) })
            try emit.finalFrame(lease)
        })) }
        _ = try frames.start(["app": "fixture", "requestId": "final-file"])
        _ = try next(frames, "final-file")
        let finalStage = try next(frames, "final-file"), terminalStage = try next(frames, "final-file")
        check("final screenshot and terminal stage carry the same retained PNG", finalStage["transitionSnapshotURL"] as? String == finalFile.absoluteString && terminalStage["transitionSnapshotURL"] as? String == finalFile.absoluteString)
        check("published final file survives the terminal callback", FileManager.default.fileExists(atPath: finalFile.path))

        let raceCounts = Locked((commit: 0, abandon: 0))
        for _ in 0..<100 {
            let response = ResponseDelivery()
            ResponseDelivery.withCurrent(response) {
                precondition(ResponseDelivery.reserve(commit: { raceCounts.change { $0.commit += 1 } }, abandon: { raceCounts.change { $0.abandon += 1 } }))
            }
            let group = DispatchGroup()
            for sent in [true, false] {
                group.enter(); DispatchQueue.global().async { if sent { response.commit() } else { response.abandon() }; group.leave() }
            }
            precondition(group.wait(timeout: .now() + 2) == .success)
        }
        check("100 concurrent write/abandon races finalize each reply once", raceCounts.value.commit + raceCounts.value.abandon == 100)

        let capacityProduced = DispatchSemaphore(value: 0), capacityCleanups = Locked(0)
        let capacity = AppCaptureCoordinator { request in
            .ready(.init(app: app, run: { emit in
                for index in 0..<17 { try emit.text("\(request.requestID):\(index)") }
                capacityProduced.signal()
            }, cancel: { capacityCleanups.change { $0 += 1 } }))
        }
        for index in 0..<33 {
            _ = try bounded { try capacity.start(["app": "fixture", "requestId": "capacity-\(index)"]) }
        }
        for _ in 0..<33 { precondition(capacityProduced.wait(timeout: .now() + 2) == .success) }
        var capacityFIFO = true
        for index in 0..<33 {
            let id = "capacity-\(index)"
            capacityFIFO = try capacityFIFO && next(capacity, id)["type"] as? String == "metadata"
            for stage in 0..<17 {
                let update = try next(capacity, id)
                capacityFIFO = capacityFIFO && update["type"] as? String == "axText" && update["text"] as? String == "\(id):\(stage)"
            }
            capacityFIFO = try capacityFIFO && next(capacity, id)["type"] as? String == "completed"
        }
        check("production coordinator preserves33 independent captures with17 queued text updates each", capacityFIFO)
        check("consuming all33 terminal stages retires each provider exactly once", capacityCleanups.value == 33)

        print("\(passed) capture coordinator checks passed using controlled providers/files; native pixels are a separate suite")
    }
}
