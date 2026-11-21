import Foundation
import CoreGraphics

struct EventStreamNativeWindow: Equatable {
    let id: UInt32
    let processIdentifier: Int32
    let frame: CGRect
    let level: Int
    let title: String?
    let ownerName: String?
}

@MainActor
protocol EventStreamContextBackend: AnyObject {
    associatedtype Node
    func window(_ id: UInt32) -> EventStreamNativeWindow?
    func matchingWindows() -> [EventStreamNativeWindow]
    func desktopWindows() -> [EventStreamNativeWindow]
    var desktopIconLevel: Int { get }
    var frontmostProcessIdentifier: Int32? { get }
    var trackedFrontmostProcessIdentifier: Int32? { get }
    func applicationExists(_ pid: Int32) -> Bool
    func application(_ pid: Int32) -> Node
    func snapshot(_ pid: Int32, fallbackName: String?) -> EventStreamApp?
    func string(_ node: Node, _ attribute: String) -> String?
    func node(_ node: Node, _ attribute: String) -> Node?
    func nodes(_ node: Node, _ attribute: String) -> [Node]
    func windowID(_ node: Node) -> UInt32?
    func processIdentifier(_ node: Node) -> Int32?
    func frame(_ node: Node) -> CGRect?
    func url(_ node: Node) -> URL?
    func hitTest(_ point: CGPoint) -> Node?
    func directTitle(_ node: Node) -> String?
    func describe(_ node: Node) -> EventStreamAXElement
    func describeEndpoint(_ node: Node, titleOverride: String?) -> EventStreamAXElement
}

extension EventStreamContextBackend {
    var trackedFrontmostProcessIdentifier: Int32? { frontmostProcessIdentifier }
}

struct EventStreamCaptureContext<Node> {
    let application: Node
    let window: Node
    let focusedElement: Node?
    let nativeWindow: EventStreamNativeWindow
}

enum EventStreamCaptureContextError: Error, Equatable {
    case noFrontmostApplication, invalidProcessIdentifier, noPrimaryWindow, windowUnavailable
}

// Recorder context helpers. The native backend supplies actual AX/CGWindow
// queries; the same selection runs against controlled nodes.
@MainActor
final class EventStreamContextResolver<Backend: EventStreamContextBackend> {
    let backend: Backend
    private(set) var windowURLs: [UInt32: URL] = [:]
    init(backend: Backend) { self.backend = backend }
    func clearWindowURLs() { windowURLs.removeAll() }
    // nil removes the prior capture URL.
    func recordCapturedURL(_ url:URL?,for windowID:UInt32) {windowURLs[windowID]=url}

    // Direct ID, Finder Desktop, then exact bounds and title.
    // If multiple candidates survive the title comparison, take the first.
    func matchingWindow(for node: Backend.Node, applicationPID pid: Int32,
                        candidates supplied: [EventStreamNativeWindow]? = nil) -> EventStreamNativeWindow? {
        if let id = backend.windowID(node), let window = backend.window(id) { return window }
        if backend.string(node, "AXRole") == "AXScrollArea",
           backend.snapshot(pid, fallbackName: nil)?.bundleIdentifier == "com.apple.finder",
           let desktop = backend.desktopWindows().first(where: {
               $0.level == backend.desktopIconLevel && $0.processIdentifier == pid
           }) { return desktop }
        guard let frame = backend.frame(node), !frame.isEmpty,
              let title = backend.string(node, "AXTitle") else { return nil }
        var candidates = (supplied ?? backend.matchingWindows()).filter {
            $0.processIdentifier == pid && $0.frame == frame
        }
        if candidates.count > 1 { candidates = candidates.filter { $0.title == title } }
        return candidates.first
    }

    func keyboardTarget(_ identity: EventStreamEventTargetIdentity) -> EventStreamEventTargetIdentity {
        guard identity.windowID == nil else { return identity }
        guard let pid = identity.processIdentifier ?? backend.frontmostProcessIdentifier,
              backend.applicationExists(pid),
              let focused = backend.node(backend.application(pid), "AXFocusedWindow"),
              let window = matchingWindow(for: focused, applicationPID: pid) else { return identity }
        return .init(processIdentifier: pid, windowID: window.id)
    }

    func resolve(_ identity: EventStreamEventTargetIdentity) -> EventStreamEventTarget {
        let raw = identity.windowID.flatMap(backend.window)
        let app = identity.processIdentifier.flatMap { backend.snapshot($0, fallbackName: raw?.ownerName) }
        let window = identity.windowID.flatMap { id -> EventStreamWindow? in
            if let current = axWindow(id) { return describeWindow(current.node, id: current.window.id, fallbackTitle: current.window.title) }
            return raw.map { .init(title: nonempty($0.title), url: windowURLs[$0.id]?.absoluteString, windowID: $0.id) }
        }
        return .init(identity: identity, app: app, window: window)
    }

    func focusedTarget(_ target: EventStreamEventTarget?) -> Backend.Node? {
        let pid: Int32
        if let target {
            if let explicit = target.identity.processIdentifier {
                guard explicit > 0 else { return nil }
                pid = explicit
            } else {
                guard target.identity.windowID == nil, let frontmost = backend.trackedFrontmostProcessIdentifier else { return nil }
                pid = frontmost
            }
        } else {
            guard let frontmost = backend.trackedFrontmostProcessIdentifier else { return nil }
            pid = frontmost
        }
        guard backend.applicationExists(pid) else { return nil }
        let app = backend.application(pid)
        guard let primary = primaryWindow(app), let window = matchingWindow(for: primary, applicationPID: pid),
              target?.identity.windowID == nil || target?.identity.windowID == window.id else { return nil }
        return backend.node(app, "AXFocusedUIElement")
    }

    // Capture-context selection differs from focusedTarget:
    // explicit window first, then a live positive PID, otherwise tracked focus.
    func captureContext(_ target: EventStreamEventTarget?) throws -> EventStreamCaptureContext<Backend.Node> {
        if let id = target?.identity.windowID, let explicit = axWindow(id) {
            let pid = explicit.window.processIdentifier
            guard let window = matchingWindow(for: explicit.node, applicationPID: pid) else {
                throw EventStreamCaptureContextError.windowUnavailable
            }
            // forWindow: passes no focused element. Failure
            // after resolving that window does not fall back to another app.
            return .init(application: backend.application(pid), window: explicit.node,
                         focusedElement: nil, nativeWindow: window)
        }
        let pid: Int32
        if let explicit = target?.identity.processIdentifier, explicit > 0, backend.applicationExists(explicit) {
            pid = explicit
        } else {
            guard let frontmost = backend.trackedFrontmostProcessIdentifier else {
                throw EventStreamCaptureContextError.noFrontmostApplication
            }
            pid = frontmost
        }
        guard pid > 0 else { throw EventStreamCaptureContextError.invalidProcessIdentifier }
        let app = backend.application(pid)
        guard let primary = primaryWindow(app) else { throw EventStreamCaptureContextError.noPrimaryWindow }
        guard let window = matchingWindow(for: primary, applicationPID: pid) else {
            throw EventStreamCaptureContextError.windowUnavailable
        }
        return .init(application: app, window: primary, focusedElement: backend.node(app, "AXFocusedUIElement"),
                     nativeWindow: window)
    }

    // Text flush fills app and
    // window independently. Captured metadata is never refreshed at flush.
    func textContext(_ target: EventStreamEventTarget?) -> (EventStreamApp?, EventStreamWindow?) {
        let app = target?.app ?? backend.frontmostProcessIdentifier.flatMap { backend.snapshot($0, fallbackName: nil) }
        let window: EventStreamWindow?
        if let captured = target?.window { window = captured }
        else if let current = try? captureContext(nil) {
            window = describeWindow(current.window, id: current.nativeWindow.id, fallbackTitle: nil)
        } else { window = nil }
        return (app, window)
    }

    func endpoint(at point: CGPoint, target: EventStreamEventTarget) -> EventStreamMouseInteractionDragEndpoint? {
        guard let hit = backend.hitTest(point) else { return nil }
        var selected = hit
        if ["AXStaticText", "AXImage"].contains(backend.string(hit, "AXRole") ?? "") {
            let roles = EventStreamInteractionPolicy.interactiveRoles.union(["AXRow", "AXTextArea", "AXTextField"])
            selected = ancestor(of: hit, maxDepth: 4) { roles.contains(backend.string($0, "AXRole") ?? "") } ?? hit
        }
        let rowTitle = backend.string(selected, "AXRole") == "AXRow" ? backend.directTitle(hit) : nil
        let app = target.app ?? backend.processIdentifier(hit).flatMap { backend.snapshot($0, fallbackName: nil) }
        let window = target.window ?? window(of: hit)
        let element = backend.describeEndpoint(selected, titleOverride: rowTitle)
        return .init(app: app, window: window, element: element)
    }

    func window(of element: Backend.Node) -> EventStreamWindow? {
        let selected = backend.node(element, "AXWindow") ?? ancestor(of: element, maxDepth: 300) {
            backend.string($0, "AXRole") == "AXWindow"
        }
        guard let selected else { return nil }
        return describeWindow(selected, id: backend.windowID(selected), fallbackTitle: nil, dropEmptyURL: true)
    }

    private func axWindow(_ id: UInt32) -> (node: Backend.Node, window: EventStreamNativeWindow)? {
        guard let window = backend.window(id) else { return nil }
        let app = backend.application(window.processIdentifier)
        let candidates = backend.matchingWindows()
        for node in backend.nodes(app, "AXWindows") {
            if matchingWindow(for: node, applicationPID: window.processIdentifier, candidates: candidates)?.id == id {
                return (node, window)
            }
        }
        return nil
    }

    private func primaryWindow(_ app: Backend.Node) -> Backend.Node? {
        backend.node(app, "AXFocusedWindow") ?? backend.node(app, "AXMainWindow") ?? backend.nodes(app, "AXWindows").last
    }

    private func describeWindow(_ node: Backend.Node, id: UInt32?, fallbackTitle: String?, dropEmptyURL: Bool = false) -> EventStreamWindow {
        let url = backend.url(node) ?? id.flatMap { windowURLs[$0] }
        if let id { windowURLs[id] = url }
        return .init(title: nonempty(backend.string(node, "AXTitle")) ?? nonempty(fallbackTitle),
                     url: dropEmptyURL ? nonempty(url?.absoluteString) : url?.absoluteString, windowID: id)
    }

    // The iterator starts at depth zero and includes maxDepth itself:
    // depth 4 visits self plus four parents, not four nodes.
    private func ancestor(of node: Backend.Node, maxDepth: Int, matches: (Backend.Node) -> Bool) -> Backend.Node? {
        for node in AXParentChain(start: node, maximumDepth: maxDepth, parent: { self.backend.node($0, "AXParent") }) {
            if matches(node) { return node }
        }
        return nil
    }

    private func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
}
