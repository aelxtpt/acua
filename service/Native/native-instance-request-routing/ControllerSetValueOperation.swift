import Foundation

struct ControllerSetValueParameters: Sendable {
    let elementID: Int
    let value: String
    let autosubmitSearchFields: Bool
    let returnAppSnapshot: Bool
}
enum ControllerSetValueFailure: Error, Equatable { case valueNotSettable }

enum ControllerFieldAutosubmit {
    /// Short-circuit these captured/generic reads in this order.
    static func required(enabled: Bool, subrole: () -> String?, identifier: () -> String?,
                         keyShortcuts: () -> String?) -> Bool {
        enabled && (subrole() == "AXSearchField" || identifier() == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD" || keyShortcuts() == "⌘L")
    }
}

@MainActor protocol ControllerSetValueBackend {
    associatedtype Element: Sendable
    associatedtype Tree: Sendable
    associatedtype Cache: Sendable
    associatedtype AppSnapshot: Sendable
    func prepare(_ id: Int) async throws -> ControllerClickPrepared<Tree, Element>
    func isValueSettable(_ element: Element) -> Bool
    func focusFieldIfNeeded(_ element: Element, tree: Tree) async throws
    func setStringValue(_ text: String, on element: Element) throws
    func subrole(_ element: Element) -> String?
    func identifier(_ element: Element) -> String?
    func keyShortcuts(_ element: Element) -> String?
    func ensureFocusEnforcer()
    var believesFocused: Bool? { get }
    var lastTree: Tree? { get }
    func captureForFocus() async throws -> Tree
    func enforceFocus(in tree: Tree) async throws
    func pressReturn() async throws
    var needsUISettleBeforeAppSnapshot: Bool { get nonmutating set }
    func settle() async throws -> Cache?
    func capture(cache: Cache?) async throws -> AppSnapshot
}

@MainActor struct ControllerSetValueOperation<Backend: ControllerSetValueBackend> {
    let backend: Backend
    func setValue(_ parameters: ControllerSetValueParameters) async throws -> Backend.AppSnapshot? {
        let prepared = try await backend.prepare(parameters.elementID)
        guard backend.isValueSettable(prepared.element) else { throw ControllerSetValueFailure.valueNotSettable }
        try await backend.focusFieldIfNeeded(prepared.element, tree: prepared.tree)
        try backend.setStringValue(parameters.value, on: prepared.element)
        if ControllerFieldAutosubmit.required(enabled: parameters.autosubmitSearchFields,
            subrole: { backend.subrole(prepared.element) }, identifier: { backend.identifier(prepared.element) },
            keyShortcuts: { backend.keyShortcuts(prepared.element) }) {
            backend.ensureFocusEnforcer()
            // A known false state still enforces focus. Only nil skips it.
            if backend.believesFocused != nil {
                let tree: Backend.Tree
                if let previous = backend.lastTree { tree = previous }
                else { tree = try await backend.captureForFocus() }
                try await backend.enforceFocus(in: tree)
            }
            try await backend.pressReturn()
        }
        guard parameters.returnAppSnapshot else { backend.needsUISettleBeforeAppSnapshot = true; return nil }
        backend.needsUISettleBeforeAppSnapshot = false
        let cache = try await backend.settle()
        return try await backend.capture(cache: cache)
    }
}
