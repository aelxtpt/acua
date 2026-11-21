import Foundation
import CoreGraphics

enum ControllerTextSelectionMode: UInt8, Sendable { case text, cursorBefore, cursorAfter }
struct ControllerTextSelectionParameters: Sendable {
    let elementID: Int
    let text: String
    var prefix: String? = nil
    var suffix: String? = nil
    var selection: ControllerTextSelectionMode = .text
    var returnAppSnapshot = true
}
enum ControllerTextSelectionFailure: Error, Equatable { case selectionNotSettable, sourceRangeUnavailable }

@MainActor protocol ControllerTextSelectionBackend {
    associatedtype Element: Sendable
    associatedtype Tree: Sendable
    associatedtype Cursor: Sendable
    associatedtype Cache: Sendable
    associatedtype AppSnapshot: Sendable
    func prepare(_ id: Int) async throws -> (element: Element, tree: Tree)
    func selectionSettable(_ element: Element) -> Bool
    func sourceRange(in tree: Tree, parameters: ControllerTextSelectionParameters) -> NSRange?
    var cursorEnabled: Bool { get }
    func bounds(for range: NSRange, element: Element) throws -> CGRect?
    func reveal(_ element: Element, frame: CGRect) async throws -> Bool
    func windowFrame(_ tree: Tree) -> CGRect
    func ensureCursor() -> Cursor
    func windowID(_ tree: Tree) -> UInt32
    func move(_ cursor: Cursor, point: CGPoint, windowID: UInt32) async
    func focus(_ element: Element, tree: Tree) async throws
    func write(_ range: NSRange, element: Element) throws
    var needsUISettleBeforeAppSnapshot: Bool { get nonmutating set }
    func settle() async throws -> Cache?
    func capture(cache: Cache?) async throws -> AppSnapshot
}

@MainActor struct ControllerTextSelection<Backend: ControllerTextSelectionBackend> {
    let backend: Backend
    static func cursorPoint(frame: CGRect, window: CGRect) -> CGPoint {
        // Clamp the selection's maximum corner. The comparison order is
        // deliberate: it fixes how non-finite values resolve.
        var x = frame.maxX > window.minX ? frame.maxX : window.minX
        if window.maxX < x { x = window.maxX }
        var y = frame.maxY > window.minY ? frame.maxY : window.minY
        if window.maxY < y { y = window.maxY }
        return .init(x: x, y: y)
    }
    func select(_ parameters: ControllerTextSelectionParameters) async throws -> Backend.AppSnapshot? {
        let prepared = try await backend.prepare(parameters.elementID)
        guard backend.selectionSettable(prepared.element) else { throw ControllerTextSelectionFailure.selectionNotSettable }
        guard var range = backend.sourceRange(in: prepared.tree, parameters: parameters) else {
            throw ControllerTextSelectionFailure.sourceRangeUnavailable
        }
        switch parameters.selection {
        case .text: break
        case .cursorBefore: range.length = 0
        case .cursorAfter: range.location += range.length; range.length = 0
        }
        if backend.cursorEnabled, var frame = try? backend.bounds(for: range, element: prepared.element) {
            let changed = try await backend.reveal(prepared.element, frame: frame)
            if changed, let fresh = try? backend.bounds(for: range, element: prepared.element) { frame = fresh }
            let point = Self.cursorPoint(frame: frame, window: backend.windowFrame(prepared.tree))
            let cursor = backend.ensureCursor()
            let window = backend.windowID(prepared.tree)
            await backend.move(cursor, point: point, windowID: window)
        }
        try await backend.focus(prepared.element, tree: prepared.tree)
        try backend.write(range, element: prepared.element)
        guard parameters.returnAppSnapshot else { backend.needsUISettleBeforeAppSnapshot = true; return nil }
        backend.needsUISettleBeforeAppSnapshot = false
        let cache = try await backend.settle()
        return try await backend.capture(cache: cache)
    }
}
