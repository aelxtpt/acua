import AppKit
import ApplicationServices

/// Ordinary native automation capture through the shared EventStream pipeline.
/// Retains the render IDs and source nodes as one snapshot.
@MainActor
final class NativeAutomationTree {
    @MainActor struct Snapshot {
        let processKey: String
        let windowID: UInt32
        let selection: EventStreamNativeSystemSelection
        let text: String

        var revision: EventStreamNativeTreeRevision.Revision { selection.windowRevision }

        func item(for id: Int) -> EventStreamCollectedItem<EventStreamAXNode>? {
            revision.item(for: id)
        }

        func element(for id: Int) -> AXUIElement? {
            item(for: id)?.node.element.element
        }

        func sourceRange(for id: Int, text: String, prefix: String? = nil, suffix: String? = nil,
                         selection: String = "text") throws -> NSRange {
            guard ["text", "cursor_before", "cursor_after"].contains(selection) else {
                throw ServiceError(.unhandledEvent, "Unknown text selection mode")
            }
            guard let item = item(for: id) else {
                throw ServiceError(.accessibilityError, "Element ID is not part of the native snapshot")
            }
            return try NativeAutomationTree.sourceRange(in: item.node, text: text, prefix: prefix, suffix: suffix, selection: selection)
        }
    }

    static func sourceRange(in node: EventStreamTransformedNode<EventStreamAXNode>, text: String,
                            prefix: String? = nil, suffix: String? = nil, selection: String = "text") throws -> NSRange {
        guard ["text", "cursor_before", "cursor_after"].contains(selection) else {
            throw ServiceError(.unhandledEvent, "Unknown text selection mode")
        }
        var matched: NSRange?
        if let rich = node.transformedString,
           let visible = try? TextSelection.range(in: rich.description, text: text, prefix: prefix, suffix: suffix) {
            matched = rich.sourceRange(forMarkdownRange: visible)
        }
        if matched == nil, let source = node.attributedString?.string ?? node.stringValue {
            matched = try? TextSelection.range(in: source, text: text, prefix: prefix, suffix: suffix)
        }
        guard let matched, matched.location >= 0, matched.length >= 0 else {
            throw ServiceError(.accessibilityError, "Text and context did not identify one source range")
        }
        let offset = node.truncationRange?.location ?? 0
        let (location, locationOverflow) = matched.location.addingReportingOverflow(offset)
        let (end, endOverflow) = location.addingReportingOverflow(matched.length)
        guard offset >= 0, location >= 0, !locationOverflow, !endOverflow else {
            throw ServiceError(.accessibilityError, "Source text range exceeds the supported offset")
        }
        switch selection {
        case "cursor_before": return NSRange(location: location, length: 0)
        case "cursor_after": return NSRange(location: end, length: 0)
        default: return NSRange(location: location, length: matched.length)
        }
    }

    private let snapshots = EventStreamNativeSnapshots()

    func capture(app: ResolvedApp, window: AXUIElement, previous: Snapshot? = nil,
                 rootOverride: AXUIElement? = nil, disableDiff: Bool) throws -> Snapshot {
        try RequestRuntime.check()
        let key = AppResolver.processKey(app.running)
        let target = try Capture.nativeWindowTarget(window, appPID: app.running.processIdentifier)
        guard let record = Capture.windowDescription(target.windowID),
              let level = (record[kCGWindowLayer as String] as? NSNumber)?.intValue else {
            throw ServiceError(.accessibilityError, "Native capture window disappeared")
        }
        let application = snapshots.node(AXUIElementCreateApplication(app.running.processIdentifier))
        let root = snapshots.node(window)
        let focused = AX.axElement(AX.copy(application.element, kAXFocusedUIElementAttribute as String)).map { snapshots.node($0) }
        let source = EventStreamCaptureContext(application: application, window: root, focusedElement: focused,
            nativeWindow: EventStreamNativeWindow(id: target.windowID, processIdentifier: target.ownerPID,
                frame: target.screenFrame, level: level, title: AX.string(window, kAXTitleAttribute as String), ownerName: app.displayName))
        let predecessor = previous.flatMap { $0.processKey == key ? $0.revision : nil }
        let backend = EventStreamNativeSelectionExtractorBackend<AXAccessibilityTracker.Lease>(
            enableAccessibility: { _, _, type in AXAccessibility.acquire(for: app, fullContext: type == .fullUIContext) },
            disable: { $0.release() }, snapshots: snapshots,
            source: EventStreamNativeRawCaptureBackend(snapshots: snapshots, checkpoint: RequestRuntime.check))
        let selection = try EventStreamNativeSelectionExtractor.extract(from: source, type: .fullUIContext,
            previous: predecessor, rootOverride: rootOverride.map { snapshots.node($0) },
            performAccessibilityEnablement: true, enableAXDiffing: !disableDiff, backend: backend)
        let mode: EventStreamSelectionDescriptionMode = disableDiff ? .fullTree : .difference(from: .previous)
        let text = selection.windowRevision.eventStreamDescription(mode, lineOptions: [], ignoreDifferenceLineBudget: false)
        try RequestRuntime.check()
        guard !app.running.isTerminated, AppResolver.processKey(app.running) == key else {
            throw ServiceError(.runningApplicationNotFound, "Application exited during native tree capture")
        }
        let result = Snapshot(processKey: key, windowID: target.windowID, selection: selection, text: text)
        return result
    }

    struct ResolvedElement {
        let element: AXUIElement
        let snapshot: Snapshot
        let id: Int
        let node: EventStreamTransformedNode<EventStreamAXNode>
    }

    nonisolated static func onMain<Result>(_ body: @MainActor () throws -> Result) throws -> Result {
        try RequestRuntime.onMainThread { try MainActor.assumeIsolated { try body() } }
    }

    func resolve(_ id: Int, in observed: Snapshot, app: ResolvedApp,
                 ignoreValueChange: Bool) throws -> ResolvedElement {
        guard let expected = observed.item(for: id) else {
            throw ServiceError(.accessibilityError, "Element ID is not part of the latest native observation")
        }
        let element = expected.node.element.element
        if let monitor = observed.selection.invalidationMonitor, !monitor.requiresRefetch(element) {
            var role: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if !monitor.requiresRefetch(element) {
                guard status != .invalidUIElement else {
                    throw ServiceError(.accessibilityError, "Native element was invalidated")
                }
                try RequestRuntime.check()
                return ResolvedElement(element: element, snapshot: observed, id: id, node: expected.node)
            }
        }
        try RequestRuntime.check()
        let current = EventStreamNativeNode.construct(snapshots.node(element))
        if EventStreamElementValidation.matches(expected.node, current, ignoreValueChange: ignoreValueChange) {
            return ResolvedElement(element: element, snapshot: observed, id: id, node: current)
        }
        // First require a unique match in the existing tree with
        // value comparison enabled, then refetches and searches the entire tree.
        guard observed.revision.tree.preorder.filter({
            EventStreamElementValidation.matches(expected.node, $0.node, ignoreValueChange: false)
        }).count == 1 else {
            throw ServiceError(.accessibilityError, "Native control recovery was already ambiguous")
        }
        // Obtain a new focused window context and deliberately
        // supplies no menu-root override when rebuilding a stale tree.
        let application = AXUIElementCreateApplication(app.running.processIdentifier)
        guard let window = AX.primaryWindow(application) else {
            throw ServiceError(.accessibilityError, "Application has no current capture window")
        }
        let fresh = try capture(app: app, window: window, previous: observed, disableDiff: false)
        let matches = fresh.revision.tree.preorder.filter {
            EventStreamElementValidation.matches(expected.node, $0.node, ignoreValueChange: ignoreValueChange)
        }
        guard matches.count == 1, let item = matches.first else {
            throw ServiceError(.accessibilityError, "Native control changed, disappeared or became ambiguous")
        }
        // Internal recovery can include non-rendered nodes. Its identity is
        // retained directly; it does not publish an unobserved ID to the client.
        let refreshedID = fresh.revision.ids.values[EventStreamSnapshotAXIdentity(element: item.node.element.element)] ?? id
        return ResolvedElement(element: item.node.element.element, snapshot: fresh, id: refreshedID, node: item.node)
    }
}
