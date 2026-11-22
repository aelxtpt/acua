import Foundation
import CoreGraphics

enum ControllerPointFailure: Error, Equatable { case noFrame, cyclicAncestry }
struct ControllerPointResult: Sendable { let point: CGPoint?; let scrolled: Bool }

protocol ControllerClickablePointBackend: Sendable {
    associatedtype Node: Sendable
    associatedtype Identity: Hashable
    func identity(_ node: Node) -> Identity
    func role(_ node: Node) -> String
    func title(_ node: Node) -> String?
    func bundle(_ node: Node) -> String?
    func frame(_ node: Node) -> CGRect?
    func frameAttribute(_ node: Node, uncached: Bool) -> CGRect?
    func parent(_ node: Node, uncached: Bool) -> Node?
    func children(_ node: Node) -> [Node]
    func actions(_ node: Node) -> [String]
    func supportedAndSettable(_ attribute: String, _ node: Node) -> Bool
    func settable(_ attribute: String, _ node: Node) -> Bool
    func performReveal(_ node: Node) throws
    func setReveal(_ node: Node) throws
    func setVisibleRect(_ rect: CGRect, _ node: Node) throws
    func scrollBar(_ node: Node, vertical: Bool) -> Node?
    func enabled(_ node: Node) -> Bool?
    func scrollValue(_ node: Node) -> CGFloat?
    func setScrollValue(_ value: CGFloat, _ node: Node) throws
    func application(_ bundle: String) -> Node?
    func hitTest(_ application: Node, _ point: CGPoint) -> Node?
    func same(_ left: Node, _ right: Node) -> Bool
    func now() -> TimeInterval
    func delay(_ seconds: TimeInterval)
}

struct ControllerClickablePoint<Backend: ControllerClickablePointBackend>: Sendable {
    let backend: Backend
    func point(_ node: Backend.Node, scrollToVisible: Bool) async throws -> ControllerPointResult {
        if let special = specialPoint(node) { return .init(point: special, scrolled: false) }
        var scrolled = false
        if scrollToVisible {
            guard let initial = backend.frame(node) else { throw ControllerPointFailure.noFrame }
            scrolled = try reveal(node, target: initial)
        }
        // Read AXFrame alone here, bypassing the cache only if reveal
        // reported a mutation. A position+size fallback belongs to the initial
        // frame getter, not to this post-reveal attribute read.
        guard let final = backend.frameAttribute(node, uncached: scrolled) else { throw ControllerPointFailure.noFrame }
        return .init(point: try visibleCenter(node, frame: final, uncached: scrolled), scrolled: scrolled)
    }
    func visibleCenter(_ node: Backend.Node, frame: CGRect, uncached: Bool) throws -> CGPoint? {
        var current: Backend.Node? = node
        var visible = CGRect.infinite
        var seen = Set<Backend.Identity>()
        while let item = current {
            guard seen.insert(backend.identity(item)).inserted else { throw ControllerPointFailure.cyclicAncestry }
            let role = backend.role(item)
            if role == "AXApplication" { break }
            // Even a nonclipping node must supply a frame here.
            guard let rect = backend.frameAttribute(item, uncached: uncached) else { return nil }
            if clips(item, role: role) {
                visible = visible.intersection(rect)
                if visible.isEmpty || visible.isNull { return nil }
            }
            if ClickableGeometry.boundary(role: role) { break }
            current = backend.parent(item, uncached: uncached)
        }
        guard visible != .infinite else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return visible.contains(center) ? center : nil
    }
    private func clips(_ node: Backend.Node, role: String) -> Bool {
        if role == "AXScrollArea" || ClickableGeometry.boundary(role: role) { return true }
        return role == "AXGroup" && ClickableGeometry.clips(role: role, actions: backend.actions(node))
    }
    func specialPoint(_ node: Backend.Node) -> CGPoint? {
        guard backend.role(node) == "AXButton", ClickableGeometry.isChessSquareTitle(backend.title(node)),
              backend.bundle(node) == "com.apple.Chess", let app = backend.application("com.apple.Chess"),
              let frame = backend.frame(node) else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let first = backend.hitTest(app, center), !backend.same(first, node),
              let parent = backend.parent(node, uncached: false), let board = backend.frame(parent) else { return nil }
        let width = board.width / 64, height = board.height / 64
        var sum = CGPoint.zero; var count = 0
        for row in 0..<64 {
            for column in 0..<64 {
                let point = CGPoint(x: board.minX + width * (CGFloat(column) + 0.5), y: board.minY + height * (CGFloat(row) + 0.5))
                if let hit = backend.hitTest(app, point), backend.same(hit, node) { sum.x += point.x; sum.y += point.y; count += 1 }
            }
        }
        return count == 0 ? nil : CGPoint(x: sum.x / CGFloat(count), y: sum.y / CGFloat(count))
    }
    func reveal(_ node: Backend.Node, target: CGRect) throws -> Bool {
        let plan = try ScrollToVisiblePlan.collect(from: node, identity: backend.identity, role: { backend.role($0) },
            actions: { backend.actions($0) }, settable: { backend.settable("AXScrollToVisible", $0) },
            parent: { backend.parent($0, uncached: false) }, checkpoint: {})
        var changed = false
        for step in plan {
            switch step {
            case .action(let item): try backend.performReveal(item); changed = true
            case .attribute(let item): try backend.setReveal(item); changed = true
            case .scrollArea(let item): changed = try scrollArea(item, target: target) || changed
            }
        }
        if changed {
            let started = backend.now()
            while backend.now() - started <= 0.5 {
                if let frame = backend.frameAttribute(node, uncached: true),
                   (try? visibleCenter(node, frame: frame, uncached: true)) != nil { break }
                backend.delay(0.025)
            }
        }
        return changed
    }
    func contentFrame(_ area: Backend.Node) -> CGRect {
        var pending = backend.children(area), seen = Set<Backend.Identity>(), frame = CGRect.null
        while let child = pending.popLast() {
            let role = backend.role(child)
            if role == "AXScrollBar" { continue }
            guard seen.insert(backend.identity(child)).inserted else { continue }
            if let rect = backend.frame(child), !rect.isEmpty { frame = frame.union(rect) }
            if role == "AXScrollArea" || (role == "AXGroup" && ClickableGeometry.clips(role: role, actions: backend.actions(child))) { continue }
            pending.append(contentsOf: backend.children(child))
        }
        return frame
    }
    func scrollArea(_ area: Backend.Node, target: CGRect) throws -> Bool {
        guard !target.isInfinite, !target.isEmpty, let viewport = backend.frame(area), !viewport.contains(target) else { return false }
        var changed = false, handled = false
        for vertical in [true, false] {
            guard let bar = backend.scrollBar(area, vertical: vertical), backend.enabled(bar) != false else { continue }
            let low = vertical ? target.minY : target.minX, high = vertical ? target.maxY : target.maxX
            let start = vertical ? viewport.minY : viewport.minX, end = vertical ? viewport.maxY : viewport.maxX
            if low >= start && high <= end { handled = true; continue }
            // AppKit does not expose a plain NSView document, only the controls
            // in it, so the children's union can be smaller than the viewport
            // even with the target far outside it. That made every axis look
            // unscrollable. The content always spans at least the viewport.
            let content = contentFrame(area).union(viewport)
            let extent = (vertical ? content.height : content.width) - (vertical ? viewport.height : viewport.width)
            if extent <= 0 { handled = true; continue }
            let delta: CGFloat
            if high - low <= end - start { delta = (low + high - start - end) * 0.5 }
            else if low < start { delta = low - start }
            else if end >= high { handled = true; continue }
            else { delta = high - end }
            let offset: CGFloat
            if let value = backend.scrollValue(bar) { offset = extent * (value <= 0 ? 0 : value <= 1 ? value : 1) }
            else {
                let origin = vertical ? content.minY : content.minX
                offset = min(extent, max(0, start - origin))
            }
            let moved = delta + offset
            let bounded: CGFloat = moved > 0 ? (extent >= moved ? moved : extent) : 0
            try backend.setScrollValue(bounded / extent, bar)
            handled = true; changed = true
        }
        // An axis already visible or lacking extent is handled, even though
        // no value was written. It suppresses the rectangle fallback.
        if !handled && backend.supportedAndSettable("AXMakeScreenRectVisible", area) {
            try backend.setVisibleRect(target, area); return true
        }
        return changed
    }
}
