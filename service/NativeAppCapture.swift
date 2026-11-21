import AppKit
import ApplicationServices

enum NativeAppCapture {
    private final class Failure {
        private let lock = NSLock()
        private var value: Error?
        func set(_ error: Error) { lock.lock(); value = error; lock.unlock() }
        var exists: Bool { lock.lock(); defer { lock.unlock() }; return value != nil }
    }
    private final class TextMetadata: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ url: String?) { lock.withLock { value = url } }
        var url: String? { lock.withLock { value } }
    }
    static let shared = AppCaptureCoordinator(prepare: prepare)

    static func start(_ request: JSON, native: Bool) throws -> JSON {
        try shared.start(request, checkPermissions: native ? NativeAppshotPermissions.check : nil)
    }

    private static func prepare(_ request: AppCaptureWire.Start) throws -> AppCaptureCoordinator.Preparation {
        try NativeTargetPolicy.requireAllowed(request.app)
        try Permissions.requireUnlockedScreen()
        // Missing permission remains pending. Only an actual host-window
        // dismissal may produce permissionsAbandoned; elapsed time is not one.
        guard Permissions.accessibilityGranted(), Permissions.screenRecordingGranted() else {
            throw ServiceError(.permissionsPending, "Accessibility and Screen Recording permissions are required for app capture")
        }
        let app = try AppResolver.require(request.app)
        try NativeTargetPolicy.requireAllowed(app.bundleIdentifier)
        let processKey = AppResolver.processKey(app.running)
        let root = AXUIElementCreateApplication(app.running.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
        guard let window = AX.axElement(AX.copy(root, kAXFocusedWindowAttribute as String)) ?? AX.axElement(AX.copy(root, kAXMainWindowAttribute as String)),
              let origin = AX.point(window, kAXPositionAttribute as String), let size = AX.size(window, kAXSizeAttribute as String) else {
            throw ServiceError(.accessibilityError, "Application has no accessible capture window")
        }
        let id = try AccessibilityWindowSPI.windowID(window), pid = try AccessibilityWindowSPI.actualPID(window)
        let frame = CGRect(origin: origin, size: size)
        guard CaptureLayout.valid(frame), let current = Capture.currentFrame(windowID: id, pid: pid), ScreenshotGeometry.framesMatch(frame, current) else {
            throw ServiceError(.accessibilityError, "Capture window is not onscreen or changed")
        }
        let transition = request.animationTarget.flatMap {
            NativeCaptureTransition.make(sourceFrame: frame, windowID: id, windowTitle: AX.string(window, kAXTitleAttribute as String), app: app, target: $0)
        }
        transition?.start()
        let metrics = transition?.metrics
        let response = AppCaptureWire.StartResponse(result: .started, animationDuration: metrics?.animationDuration,
            transitionSnapshotHeight: metrics.map { Double($0.snapshotHeight) }, transitionSpringResponse: metrics?.springResponse,
            transitionSpringDampingFraction: metrics?.dampingFraction)
        let reference = Capture.WindowReference(frame: frame, title: AX.string(window, kAXTitleAttribute as String), windowID: id)
        let plan = AppCaptureCoordinator.Plan(app: app.ipc, response: response, run: { emitter in
            var finished = false
            defer { if !finished { transition?.cancel() } }
            let scope = RequestRuntime.workerScope()
            let done = DispatchSemaphore(value: 0), group = DispatchGroup(), failure = Failure()
            let textMetadata = TextMetadata()
            @Sendable func requireCurrent() throws {
                try emitter.check()
                guard !app.running.isTerminated, AppResolver.processKey(app.running) == processKey,
                      let current = Capture.currentFrame(windowID: id, pid: pid), ScreenshotGeometry.framesMatch(frame, current) else {
                    throw ServiceError(.accessibilityError, "Capture window moved, closed or restarted")
                }
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                // AX text failure does not discard an otherwise usable image.
                try? RequestRuntime.withWorkerScope(scope, cancelled: { emitter.isCancelled }) {
                    try requireCurrent()
                    let captured = try NativeAutomationTree.onMain { try NativeAppshotText.capture(app: app, window: window) }
                    textMetadata.set(captured.selectedURL)
                    try requireCurrent()
                    try emitter.text(captured.text)
                }
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                do {
                    try RequestRuntime.withWorkerScope(scope, cancelled: { emitter.isCancelled }) {
                        try requireCurrent()
                        let image = try Capture.captureWindow(pid: pid, into: nil, matching: reference)
                        let lease = CaptureFileLease(url: image.path, remove: { Capture.removeTemporaryImage($0.path) })
                        try requireCurrent()
                        try transition?.setScreenshot(image.path)
                        try emitter.screenshot(lease)
                    }
                } catch {
                    failure.set(error)
                }
            }
            group.notify(queue: .global()) { done.signal() }
            try RequestRuntime.wait(for: done, maximumSeconds: 35)
            if failure.exists { throw AppCaptureCoordinator.CaptureFailure.screenshot }
            //0x100167E88 checks selected URL after content callbacks and
            // before waiting for the transition's final movement.
            try ActionAppSnapshotURLPolicy.check(textMetadata.url, for: app)
            try requireCurrent()
            try transition?.waitForMove()
            try requireCurrent()
            let final = try transition?.finalSnapshot()
            try requireCurrent()
            transition?.solidBackground()
            if request.version.supportsReliableFinalFrame { try emitter.finalFrame(final) }
            else {
                emitter.terminalFrame(final)
                if let transition { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { transition.complete() } }
            }
            finished = true
        }, cancel: { transition?.cancel() }, complete: {
            if request.version.supportsReliableFinalFrame { transition?.complete() }
        })
        return .ready(plan)
    }
}
