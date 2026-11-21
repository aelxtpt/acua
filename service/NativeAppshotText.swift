import AppKit
import ApplicationServices

@MainActor enum NativeAppshotText {
    struct Result: Sendable {
        let text: String
        let selectedURL: String?
    }

    //0x10016BE54 selects informationalContext, no root override/diff, and
    //0x100174FEC renders a full description with withoutElementID.
    static func capture(app: ResolvedApp, window: AXUIElement) throws -> Result {
        try RequestRuntime.check()
        let process = AppResolver.processKey(app.running)
        let target = try Capture.nativeWindowTarget(window, appPID: app.running.processIdentifier)
        guard let record = Capture.windowDescription(target.windowID),
              let level = (record[kCGWindowLayer as String] as? NSNumber)?.intValue else {
            throw ServiceError(.accessibilityError, "Appshot capture window disappeared")
        }
        let snapshots = EventStreamNativeSnapshots()
        let application = snapshots.node(AXUIElementCreateApplication(app.running.processIdentifier))
        let root = snapshots.node(window)
        let focused = AX.axElement(AX.copy(application.element, kAXFocusedUIElementAttribute as String)).map { snapshots.node($0) }
        let source = EventStreamCaptureContext(application: application, window: root, focusedElement: focused,
            nativeWindow: EventStreamNativeWindow(id: target.windowID, processIdentifier: target.ownerPID,
                frame: target.screenFrame, level: level,
                title: AX.string(window, kAXTitleAttribute as String), ownerName: app.displayName))
        let backend = EventStreamNativeSelectionExtractorBackend<NSObject>(
            enableAccessibility: { _, _, _ in preconditionFailure("Appshot capture disables accessibility enablement") },
            disable: { _ in preconditionFailure("Appshot capture never owns an accessibility assertion") },
            snapshots: snapshots,
            source: EventStreamNativeRawCaptureBackend(snapshots: snapshots, checkpoint: RequestRuntime.check))
        let selection = try EventStreamNativeSelectionExtractor.extract(from: source, type: .informationalContext,
            previous: nil, rootOverride: nil, performAccessibilityEnablement: false,
            alwaysIncludeScreenshot: false, enableAXDiffing: false, backend: backend)
        let text = selection.windowRevision.eventStreamDescription(.fullTree, lineOptions: [.withoutElementID],
            ignoreDifferenceLineBudget: false)
        try RequestRuntime.check()
        guard !app.running.isTerminated, AppResolver.processKey(app.running) == process else {
            throw ServiceError(.runningApplicationNotFound, "Application exited during Appshot text capture")
        }
        return Result(text: text, selectedURL: selection.url?.absoluteString)
    }

}
