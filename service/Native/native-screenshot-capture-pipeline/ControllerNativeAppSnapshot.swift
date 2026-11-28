import AppKit
import ApplicationServices
import Foundation

struct ControllerNativeScreenshotImageEnvironment: Sendable {
    let captureBuffer: @Sendable (ControllerScreenshotCaptureOptions) async throws -> CGImage
    let directory: @Sendable () -> URL
    static var native: Self {
        .init(captureBuffer: { try await ControllerNativeScreenshotBuffer.capture($0) }, directory: {
            if let path = ProcessInfo.processInfo.environment["ACUA_SCREENSHOT_DIRECTORY"], !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return NativeAppSnapshotImage.defaultDirectory
        })
    }
}

@MainActor final class ControllerNativeAppSnapshotSource {
    let context: EventStreamCaptureContext<EventStreamAXNode>
    let window: ControllerNativeElementContext.Node
    init(context: EventStreamCaptureContext<EventStreamAXNode>, window: ControllerNativeElementContext.Node) {
        self.context = context; self.window = window
    }
}
@MainActor final class ControllerNativeAppSnapshotPlan {
    let settings: NativeAppSnapshotImage.Settings
    let sizing: ScreenshotGeometry.NativeLayout?
    init(settings: NativeAppSnapshotImage.Settings, sizing: ScreenshotGeometry.NativeLayout?) { self.settings = settings; self.sizing = sizing }
}
@MainActor final class ControllerNativeAppSnapshotCache {
    let value: EventStreamNativeCaptureTreeCache
    init(_ value: EventStreamNativeCaptureTreeCache) { self.value = value }
}
@MainActor final class ControllerNativeAppSnapshotPrevious {
    let value: EventStreamNativeTreeRevision.Revision
    init(_ value: EventStreamNativeTreeRevision.Revision) { self.value = value }
}
@MainActor final class ControllerNativeAppSnapshotSelection {
    let value: EventStreamNativeSystemSelection
    let source: ControllerNativeAppSnapshotSource
    init(_ value: EventStreamNativeSystemSelection, source: ControllerNativeAppSnapshotSource) { self.value = value; self.source = source }
}
@MainActor final class ControllerRefetchableAppSnapshotTree {
    var selection: ControllerNativeAppSnapshotSelection
    let isAXTreeDiffingEnabled: Bool
    init(selection: ControllerNativeAppSnapshotSelection, isAXTreeDiffingEnabled: Bool) {
        self.selection = selection; self.isAXTreeDiffingEnabled = isAXTreeDiffingEnabled
    }
    func findButton(labels: Set<String>) -> Int? {
        let revision = selection.value.windowRevision
        return AccessibilityButtonSearch.find(in: revision.renderTree.preorder.map(\.elementID), labels: labels) { id in
            guard let node = revision.item(for: id)?.node else { return nil }
            return .init(role: node.role, title: node.title, description: node.description,
                value: node.value, valueDescription: node.valueDescription, help: node.help)
        }
    }
}
@MainActor final class ControllerNativeAppSnapshotImage {
    let file: ControllerTemporaryImage
    let size: CGSize
    let geometry: ScreenshotGeometry
    let mimeType: String
    init(file: ControllerTemporaryImage, size: CGSize, geometry: ScreenshotGeometry, mimeType: String) {
        self.file = file; self.size = size; self.geometry = geometry; self.mimeType = mimeType
    }
}
@MainActor struct ControllerNativeAppSnapshotAttachment {
    let text: String
    let screenshot: ControllerTemporaryImage?
    let mimeType: String?
    let screenshotNeededForContext: Bool
    let accessibilityInspectorPayload: EventStreamRenderInspectorPayload?
}

/// Snapshot-aware overrides for the existing physical-window matcher. Native
/// metadata/endpoint methods retain their established backend implementation.
@MainActor private final class ControllerAppSnapshotContextBackend: EventStreamContextBackend {
    typealias Node = EventStreamAXNode
    let resources: ControllerNativeResources
    let base: EventStreamNativeContextBackend
    init(resources: ControllerNativeResources, wrap: @escaping @MainActor (AXUIElement) -> Node) {
        self.resources = resources; base = .init(nodeProvider: wrap)
    }
    var desktopIconLevel: Int { base.desktopIconLevel }
    var frontmostProcessIdentifier: Int32? { base.frontmostProcessIdentifier }
    func applicationExists(_ pid: Int32) -> Bool { base.applicationExists(pid) }
    func application(_ pid: Int32) -> Node { base.application(pid) }
    func snapshot(_ pid: Int32, fallbackName: String?) -> EventStreamApp? { base.snapshot(pid, fallbackName: fallbackName) }
    func string(_ node: Node, _ name: String) -> String? { resources.geometry.value(name, on: contextual(node)) }
    func node(_ node: Node, _ name: String) -> Node? { base.node(node, name) }
    func nodes(_ node: Node, _ name: String) -> [Node] { base.nodes(node, name) }
    func windowID(_ node: Node) -> UInt32? { try? resources.context.identity.windowID(.init(element: node.element)) }
    func processIdentifier(_ node: Node) -> Int32? { try? ControllerAXEnablementNative.pid(.init(element: node.element), lookup: { resources.io.lookup($0)?.ordinaryPID }) }
    func frame(_ node: Node) -> CGRect? { resources.geometry.frame(contextual(node)) }
    func url(_ node: Node) -> URL? { base.url(node) }
    func hitTest(_ point: CGPoint) -> Node? { base.hitTest(point) }
    func directTitle(_ node: Node) -> String? { base.directTitle(node) }
    func describe(_ node: Node) -> EventStreamAXElement { base.describe(node) }
    func describeEndpoint(_ node: Node, titleOverride: String?) -> EventStreamAXElement { base.describeEndpoint(node, titleOverride: titleOverride) }
    func window(_ id: UInt32) -> EventStreamNativeWindow? { base.window(id) }
    func matchingWindows() -> [EventStreamNativeWindow] { base.matchingWindows() }
    func desktopWindows() -> [EventStreamNativeWindow] { base.desktopWindows() }
    func contextual(_ node: Node) -> ControllerNativeElementContext.Node {
        .init(element: .init(element: node.element), snapshot: .init(supported: node.supportedAttributeNames(),
            values: node.cachedAttributesSnapshot().mapValues { .init(raw: $0) }, requested: node.transactionAttributes))
    }
}

@MainActor final class ControllerNativeAppSnapshotBackend: ControllerAppSnapshotBackend {
    typealias Context = ControllerNativeAppSnapshotSource
    typealias Window = ControllerNativeElementContext.Node
    typealias Plan = ControllerNativeAppSnapshotPlan
    typealias Cache = ControllerNativeAppSnapshotCache
    typealias Previous = ControllerNativeAppSnapshotPrevious
    typealias Selection = ControllerNativeAppSnapshotSelection
    typealias Image = ControllerNativeAppSnapshotImage
    typealias Tree = ControllerRefetchableAppSnapshotTree
    typealias Attachment = ControllerNativeAppSnapshotAttachment
    typealias Assembly = ControllerNativeOwnerAssembly<ControllerTemporaryImage, ControllerApprovedCursor, Tree>
    typealias Owner = Assembly.Owner
    let owner: Owner
    let resources: ControllerNativeResources
    private let snapshots = EventStreamNativeSnapshots()
    init(owner: Owner, resources: ControllerNativeResources) { self.owner = owner; self.resources = resources }
    var isTerminated: Bool { owner.runningApplication.application.isTerminated }
    func terminatedError() -> any Error { ComputerUseControllerIdentityError.runningApplicationNotFound(owner.bundleIdentifier) }
    var focusedMenuBarItem: Window? { owner.currentlyFocusedMenuBarItem }
    var stageManagerEnabled: Bool { UserDefaults(suiteName: "com.apple.WindowManager")?.bool(forKey: "GloballyEnabled") == true }
    func prepareStageManager(_ context: Context) async throws { try StageManagerCapture.prepare(context.window.element.element) }
    func snapshotNode(_ node: Window) -> EventStreamAXNode {
        ControllerNativeAppSnapshotContext.snapshotNode(node, context: resources.context)
    }
    func focusedContext() throws -> Context {
        try ControllerNativeAppSnapshotContext.focused(application: owner.app, pid: owner.pid, resources: resources)
    }
    func isTransientContextFailure(_ error: any Error) -> Bool {
        (error as? EventStreamCaptureContextError) == .windowUnavailable
    }
    func waitBeforeContextRetry() async throws { try await Task.sleep(for: .milliseconds(200)) }
    func plan(_ context: Context, root: Window?, skipScreenshot: Bool) throws -> Plan {
        let settings = NativeAppSnapshotImage.Settings.current()
        guard root == nil && !skipScreenshot else { return .init(settings: settings, sizing: nil) }
        let frame = context.context.nativeWindow.frame
        let screens = NSScreen.screens
        // WindowServer frame against screens converted to the same space; see
        // CaptureLayout.screenIndex for the matching rule.
        let scale = CaptureLayout.screenIndex(for: frame, appKitScreenFrames: screens.map(\.frame)).map { screens[$0].backingScaleFactor } ?? 2
        owner.visibleRect = frame
        let sizing = ControllerScreenshotSizing.read(frame: frame, scale: scale, legacy: settings.legacySizing, normalizeToPoints: settings.normalizeToPoints)
        owner.scalingFactor = sizing.pointScale; owner.scaledScreenSize = sizing.size
        return .init(settings: settings, sizing: .init(requestedSize: sizing.size, windowOrigin: frame.origin, pointScale: sizing.pointScale, visibleSize: frame.size))
    }
    func visibleCursorWindowID() -> UInt32? { ComputerUseFeaturePreferences.cursorEnabled ? owner.virtualCursor?.visibleWindowID : nil }
    var ownerDiffingEnabled: Bool { owner.isAXTreeDiffingEnabled }
    func previousRevision() -> Previous? { owner.lastAXTree.map { .init($0.selection.value.windowRevision) } }
    func captureSelection(_ context: Context, plan: Plan, root: Window?, cache: Cache?, previous: Previous?, enableDiffing: Bool) async throws -> Selection {
        let backend = EventStreamNativeSelectionExtractorBackend<ControllerAXEnablementAssertion>(enableAccessibility: { app, window, type in
            self.resources.enablement.acquire(application: self.resources.context.context.node(.init(element: app.element)),
                window: self.resources.context.context.node(.init(element: window.element)), context: type.rawValue)
        }, disable: { $0.disable() }, snapshots: snapshots, source: .init(snapshots: snapshots))
        let value = try EventStreamNativeSelectionExtractor.extract(from: context.context, type: .fullUIContext,
            cache: cache?.value, previous: previous?.value, rootOverride: root.map(snapshotNode), performAccessibilityEnablement: false,
            enableAXDiffing: enableDiffing, backend: backend)
        return .init(value, source: context)
    }
    func captureImage(_ context: Context, plan: Plan, cursorWindowID: UInt32?) async throws -> Image {
        try await captureImage(context, plan: plan, cursorWindowID: cursorWindowID, environment: .native)
    }
    func captureImage(_ context: Context, plan: Plan, cursorWindowID: UInt32?,
                      environment: ControllerNativeScreenshotImageEnvironment) async throws -> Image {
        let window = context.context.nativeWindow
        let additional = cursorWindowID.map { [$0] } ?? []
        let ids = [window.id] + additional
        let application = ControllerNativeAppSnapshotContext.contextual(context.context.application)
        let interval = owner.signposter.beginInterval("Capture Screenshot")
        defer { owner.signposter.endInterval("Capture Screenshot", interval) }
        let image = try await environment.captureBuffer(.init(
            appName: resources.geometry.value("AXTitle", on: application) ?? "Unknown",
            imageSize: plan.sizing?.requestedSize, includedWindowIDs: ids,
            cropToFirstWindow: !additional.isEmpty, shouldBeOpaque: true, includeWindowShadow: false))
        // The source reads the application title again after the buffer await.
        // File writing belongs to this image child, before its result is joined.
        let (written, encoding) = try NativeAppSnapshotImage.writeFileWithinBudget(image,
            appName: resources.geometry.value("AXTitle", on: application) ?? "Unknown",
            directory: environment.directory(), settings: plan.settings)
        let log = resources.context.log
        let file = ControllerTemporaryImage.adoptingNative(written.url, filePath: written.path, log: log)
        let geometry = ScreenshotGeometry(windowID: window.id, ownerPID: window.processIdentifier,
            screenFrame: window.frame, pixelWidth: image.width, pixelHeight: image.height,
            includedWindowIDs: ids, nativeLayout: plan.sizing)
        return .init(file: file, size: .init(width: image.width, height: image.height), geometry: geometry,
            mimeType: encoding.type.preferredMIMEType ?? "application/octet-stream")
    }
    var classifierEnabled: Bool { UserDefaults.standard.object(forKey: "feature/appSnapshotClassifier") as? Bool ?? true }
    func makeTree(_ selection: Selection, diffingEnabled: Bool) throws -> Tree { .init(selection: selection, isAXTreeDiffingEnabled: diffingEnabled) }
    func makeAttachment(_ selection: Selection, image: Image?, classifierEnabled: Bool) throws -> Attachment {
        let revision = selection.value.windowRevision
        return .init(text: revision.eventStreamDescription(.difference(from: .previous), lineOptions: [], ignoreDifferenceLineBudget: false),
            screenshot: image?.file, mimeType: image?.mimeType,
            screenshotNeededForContext: image != nil && !classifierEnabled && selection.value.screenshotNeededForContext,
            accessibilityInspectorPayload: revision.renderTreeInspectorPayload())
    }
    func retainImage(_ image: Image) { var files = owner.appSnapshotImageFiles; files.insert(image.file); owner.appSnapshotImageFiles = files }
    func publishTree(_ tree: Tree) { owner.lastAXTree = tree }
    func publishWindow(_ selection: Selection) { owner.lastWindow = (selection.value.applicationWindow.nativeWindow.id, selection.source.window) }
    func notifyDidUpdate() { owner.environment.notificationCenter.post(name: .init("computerUseAppControllerDidUpdateAppSnapshot"), object: owner) }
    func imageSize(_ image: Image) -> CGSize { image.size }
}

@MainActor final class ControllerNativeAppController {
    typealias Backend = ControllerNativeAppSnapshotBackend
    typealias AppSnapshot = ControllerAppSnapshotOperation<Backend>.Result
    let owner: Backend.Owner
    let resources: ControllerNativeResources
    private let appSnapshot: ControllerAppSnapshotOperation<Backend>
    init(target: ComputerUseApplicationTarget, chatID: String?, mcpRuntime: UInt8, isAXTreeDiffingEnabled: Bool,
         assembly: Backend.Assembly) throws {
        owner = try assembly.makeOwner(target: target, chatID: chatID, mcpRuntime: mcpRuntime, isAXTreeDiffingEnabled: isAXTreeDiffingEnabled)
        resources = assembly.resources
        appSnapshot = .init(backend: .init(owner: owner, resources: resources))
    }
    init(owner: Backend.Owner, resources: ControllerNativeResources) {
        self.owner = owner; self.resources = resources
        appSnapshot = .init(backend: .init(owner: owner, resources: resources))
    }
    func activate() { owner.activate() }
    func deactivate() { owner.deactivate() }
    func updateAppSnapshot(treeCache: ControllerNativeAppSnapshotCache? = nil, disableAXDiffing: Bool, skipScreenshot: Bool) async throws -> AppSnapshot {
        try await appSnapshot.capture(cache: treeCache, disableAXDiffing: disableAXDiffing, skipScreenshot: skipScreenshot)
    }
}

/// The capture and synchronous refetch paths share this immutable context
/// binding. Retained nodes capture no controller, owner or backend.
@MainActor enum ControllerNativeAppSnapshotContext {
    typealias Window = ControllerNativeElementContext.Node
    static func snapshotNode(_ node: Window, context: ControllerNativeElementContext) -> EventStreamAXNode {
        .init(node.element.element, supportedAttributes: node.snapshot.supported,
            attributes: node.snapshot.values.mapValues(\.raw), transactionAttributes: node.snapshot.requested,
            related: { snapshotNode(context.context.node(.init(element: $0)), context: context) },
            attributeReader: { try? context.context.environment.read(node.element, $0)?.raw })
    }
    static func contextual(_ node: EventStreamAXNode) -> Window {
        .init(element: .init(element: node.element), snapshot: .init(supported: node.supportedAttributeNames(),
            values: node.cachedAttributesSnapshot().mapValues { .init(raw: $0) }, requested: node.transactionAttributes))
    }
    static func focused(application: Window, pid: Int32, resources: ControllerNativeResources) throws -> ControllerNativeAppSnapshotSource {
        let context = resources.context
        guard let primary = context.context.primaryWindow(application) else { throw EventStreamCaptureContextError.noPrimaryWindow }
        let backend = ControllerAppSnapshotContextBackend(resources: resources, wrap: { snapshotNode(context.context.node(.init(element: $0)), context: context) })
        let window = snapshotNode(primary, context: context)
        guard let nativeWindow = EventStreamContextResolver(backend: backend).matchingWindow(for: window, applicationPID: pid) else {
            throw EventStreamCaptureContextError.windowUnavailable
        }
        let focused = ControllerGlobalFocusNative.element("AXFocusedUIElement", application, context: context).map { snapshotNode($0, context: context) }
        return .init(context: .init(application: snapshotNode(application, context: context), window: window, focusedElement: focused, nativeWindow: nativeWindow), window: primary)
    }
}
