import AppKit
import ApplicationServices

@MainActor
final class EventStreamNativeContextBackend: EventStreamContextBackend {
    typealias Node = EventStreamAXNode
    typealias NodeProvider = @MainActor (AXUIElement)->Node
    private let applications = EventStreamApplicationResolver()
    private let nodeProvider:NodeProvider?
    private let windowReader: ((UInt32) -> EventStreamNativeWindow?)?
    private let listReader: ((CGWindowListOption) -> [EventStreamNativeWindow])?
    init(nodeProvider:NodeProvider?=nil, windowReader:((UInt32)->EventStreamNativeWindow?)?=nil,
         listReader:((CGWindowListOption)->[EventStreamNativeWindow])?=nil) {
        self.nodeProvider=nodeProvider;self.windowReader=windowReader;self.listReader=listReader
    }
    private func makeNode(_ element:AXUIElement)->Node {nodeProvider?(element) ?? Node(element)}
    var desktopIconLevel: Int { Int(CGWindowLevelForKey(.desktopIconWindow)) }
    var frontmostProcessIdentifier: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var trackedFrontmostProcessIdentifier: Int32? { EventStreamNativeFrontmostTracker.shared.application?.processIdentifier }

    func applicationExists(_ pid: Int32) -> Bool { NSRunningApplication(processIdentifier: pid) != nil }
    func application(_ pid: Int32) -> Node { makeNode(AXUIElementCreateApplication(pid)) }
    func snapshot(_ pid: Int32, fallbackName: String?) -> EventStreamApp? {
        applications.snapshot(processIdentifier: pid, fallbackName: fallbackName)
    }
    func string(_ node: Node, _ attribute: String) -> String? { node.attribute(attribute) as? String }
    func node(_ node: Node, _ attribute: String) -> Node? {
        guard let raw = node.attribute(attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return makeNode(unsafeBitCast(raw, to: AXUIElement.self))
    }
    func nodes(_ node: Node, _ attribute: String) -> [Node] {
        guard let values = node.attribute(attribute) as? [AnyObject] else { return [] }
        return values.compactMap {
            guard CFGetTypeID($0) == AXUIElementGetTypeID() else { return nil }
            return makeNode(unsafeBitCast($0, to: AXUIElement.self))
        }
    }
    func windowID(_ node: Node) -> UInt32? { try? AccessibilityWindowSPI.windowID(node.element) }
    func processIdentifier(_ node: Node) -> Int32? {
        var pid: Int32 = -1
        return AXUIElementGetPid(node.element, &pid) == .success ? pid : nil
    }
    func frame(_ node: Node) -> CGRect? {
        guard let position = node.attribute("AXPosition"), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = node.attribute("AXSize"), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let p = unsafeBitCast(position, to: AXValue.self), s = unsafeBitCast(size, to: AXValue.self)
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetType(p) == .cgPoint, AXValueGetValue(p, .cgPoint, &point),
              AXValueGetType(s) == .cgSize, AXValueGetValue(s, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    func url(_ node: Node) -> URL? { node.attribute("AXURL") as? URL }
    func hitTest(_ point: CGPoint) -> Node? {
        let x = Float(point.x), y = Float(point.y)
        guard x.isFinite, y.isFinite else { return nil }
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), x, y, &element) == .success,
              let element else { return nil }
        return makeNode(element)
    }
    func directTitle(_ node: Node) -> String? { EventStreamAXContext.reader().directTitle(node) }
    func describe(_ node: Node) -> EventStreamAXElement { EventStreamAXContext.reader().describe(node) }
    func describeEndpoint(_ node: Node, titleOverride: String?) -> EventStreamAXElement {
        EventStreamAXContext.reader().describeEndpoint(node, titleOverride: titleOverride)
    }

    func window(_ id: UInt32) -> EventStreamNativeWindow? {
        if let windowReader { return windowReader(id) }
        return WindowDescription.lookup(id).flatMap(windowRecord)
    }
    func matchingWindows() -> [EventStreamNativeWindow] {
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        return list([.optionOnScreenOnly, .excludeDesktopElements]).filter {
            $0.level < menuLevel && $0.processIdentifier != getpid()
        }
    }
    func desktopWindows() -> [EventStreamNativeWindow] { list(.optionOnScreenOnly) }
    private func list(_ options: CGWindowListOption, relativeTo id: UInt32 = 0) -> [EventStreamNativeWindow] {
        if let listReader { return listReader(options) }
        guard let list = CGWindowListCopyWindowInfo(options, id) as? [[String: Any]] else { return [] }
        return list.compactMap(windowRecord)
    }
    private func windowRecord(_ value: [String: Any]) -> EventStreamNativeWindow? {
        guard let idNumber = value[kCGWindowNumber as String] as? NSNumber,
                  let id = UInt32(exactly: idNumber.int64Value),
                  let pidNumber = value[kCGWindowOwnerPID as String] as? NSNumber,
                  let pid = Int32(exactly: pidNumber.int64Value),
                  let bounds = value[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  let level = value[kCGWindowLayer as String] as? Int else { return nil }
        return .init(id: id, processIdentifier: pid, frame: frame, level: level,
            title: value[kCGWindowName as String] as? String, ownerName: value[kCGWindowOwnerName as String] as? String)
    }
}

// Concrete providers for the input builder; creating this object does not start
// observation. The complete producer still owns tap, AX observers and records.
@MainActor
final class EventStreamNativeContext {
    let backend:EventStreamNativeContextBackend
    let resolver: EventStreamContextResolver<EventStreamNativeContextBackend>
    init(nodeProvider:EventStreamNativeContextBackend.NodeProvider?=nil) {
        backend = .init(nodeProvider:nodeProvider)
        resolver = .init(backend:backend)
    }

    func makeInputBuilder(nextIdentity: @escaping () -> EventStreamRecordIdentity,
                          isRecording: @escaping () -> Bool,
                          fallbackProcessIdentifier: @escaping () -> Int32?,
                          shouldCaptureApplication: @escaping (NSRunningApplication) -> Bool,
                          resolveTextContext: ((EventStreamEventTarget?) -> (EventStreamApp?, EventStreamWindow?))? = nil,
                          sleep:@escaping (Duration) async throws->Void = {try await ContinuousClock().sleep(for:$0)},
                          lifetimeOwner:@escaping ()->AnyObject? = {nil},
                          emitText: @escaping (EventStreamRecord) -> Void,
                          prepare: @escaping (EventStreamPreparedInteraction) -> Void) -> EventStreamInputRecordBuilder<EventStreamAXNode> {
        .init(nextIdentity: nextIdentity, isRecording: isRecording,
            fallbackProcessIdentifier: fallbackProcessIdentifier,
            capturePermitted: { pid in
                guard let pid, let app = NSRunningApplication(processIdentifier: pid) else { return true }
                return shouldCaptureApplication(app)
            }, keyboardTarget: resolver.keyboardTarget, resolveTarget: resolver.resolve,
            endpointAt: { self.resolver.endpoint(at: $1, target: $0) },
            focusedTarget: { target in
                guard let node = self.resolver.focusedTarget(target) else { return .init() }
                return .init(description: self.backend.describe(node), element: node)
            }, refreshTarget: { EventStreamAXContext.describe($0.element) },
            currentRole: { self.backend.string($0, "AXRole") },
            characterCount: { node in
                // The character count explicitly bypasses the snapshot cache.
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(node.element, "AXNumberOfCharacters" as CFString, &value) == .success else { return nil }
                return value as? Int
            }, resolveTextContext: resolveTextContext ?? resolver.textContext,sleep:sleep,lifetimeOwner:lifetimeOwner, emitText: emitText, prepare: prepare)
    }

    func makeAXCapture<Revision>(
        captureTree: @escaping (EventStreamCaptureContext<EventStreamAXNode>, Revision?) async throws -> EventStreamAXTreeCapture<Revision>,
        render: @escaping (EventStreamAXTreeCapture<Revision>, EventStreamAXTree.Mode, Bool, Bool) -> String
    ) -> EventStreamAXCapture<EventStreamCaptureContext<EventStreamAXNode>, Revision> {
        .init(resolveContext: resolver.captureContext, contextWindowID: { $0.nativeWindow.id },
              captureTree: captureTree, render: render)
    }
}
