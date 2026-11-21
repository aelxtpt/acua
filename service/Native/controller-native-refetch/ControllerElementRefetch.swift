import Foundation

struct ControllerElementInvalidation<Key: Hashable> {
    let layoutChanged: Bool
    let destroyed: Set<Key>
}
enum ControllerElementRefetchFailure: Error, Equatable {
    enum Reason: Int, Sendable { case missingMonitor = 0, ambiguousBeforeRefetch = 1, ambiguousAfterRefetch = 2, invalidElement = 3, missingAfterRefetch = 4 }
    case missingID(Int)
    case unavailable(Reason)
}
enum ControllerElementRefetchLog: String {
    case monitorRead = "2d97588fe9ab5437880d"
    case mustRefresh = "6d5e4995cfa8d82dd2d6"
    case freshMatches = "235b794f45a99f54f4d4"
    case mustRefetchTree = "d7374133c79b74d3dcca"
    case ambiguousBeforeRefetch = "e3c67794a7a4024c98bb"
    case missingAfterRefetch = "38bc56efd066c04f193d"
    case ambiguousAfterRefetch = "017fcd2d38431dc48340"
    case refetched = "c9791c7df98014888474"
}

@MainActor protocol ControllerElementRefetchBackend {
    associatedtype Element
    associatedtype Key: Hashable
    associatedtype Handle
    func item(for id: Int) -> Element?
    func monitorSnapshot() -> ControllerElementInvalidation<Key>?
    func identity(_ element: Element) -> Key
    func roleStatus(_ element: Element) -> Int32
    func fresh(_ element: Element) -> Element
    func matches(_ expected: Element, _ candidate: Element, ignoreValueChange: Bool) -> Bool
    func elements() -> [Element]
    func refetchTree() throws
    func box(_ element: Element) -> Handle
    func log(_ message: ControllerElementRefetchLog)
}

@MainActor struct ControllerElementRefetch<Backend: ControllerElementRefetchBackend> {
    let backend: Backend
    func resolve(id: Int, validateElement: Bool) throws -> Backend.Handle {
        guard let element = backend.item(for: id) else { throw ControllerElementRefetchFailure.missingID(id) }
        return try resolve(element, validateElement: validateElement, ignoreValueChange: false)
    }
    /// Snapshot the monitor once. A missing observer inside an existing
    /// monitor is not a separate invalidation condition at this call site.
    func resolve(_ element: Backend.Element, validateElement: Bool, ignoreValueChange: Bool) throws -> Backend.Handle {
        guard let snapshot = backend.monitorSnapshot() else { throw ControllerElementRefetchFailure.unavailable(.missingMonitor) }
        backend.log(.monitorRead)
        if !snapshot.layoutChanged && !snapshot.destroyed.contains(backend.identity(element)) {
            if validateElement && backend.roleStatus(element) == -25202 { throw ControllerElementRefetchFailure.unavailable(.invalidElement) }
            return backend.box(element)
        }
        backend.log(.mustRefresh)
        let fresh = backend.fresh(element)
        if backend.matches(element, fresh, ignoreValueChange: ignoreValueChange) {
            backend.log(.freshMatches)
            return backend.box(fresh)
        }
        backend.log(.mustRefetchTree)
        // Scan the complete main tree and retain every match. The
        // old-tree uniqueness test always includes the value, even for setters.
        let old = backend.elements().filter { backend.matches(element, $0, ignoreValueChange: false) }
        guard old.count == 1 else {
            backend.log(.ambiguousBeforeRefetch)
            throw ControllerElementRefetchFailure.unavailable(.ambiguousBeforeRefetch)
        }
        try backend.refetchTree()
        let matches = backend.elements().filter { backend.matches(element, $0, ignoreValueChange: ignoreValueChange) }
        if matches.isEmpty {
            backend.log(.missingAfterRefetch)
            throw ControllerElementRefetchFailure.unavailable(.missingAfterRefetch)
        }
        guard matches.count == 1 else {
            backend.log(.ambiguousAfterRefetch)
            throw ControllerElementRefetchFailure.unavailable(.ambiguousAfterRefetch)
        }
        backend.log(.refetched)
        return backend.box(matches[0])
    }
}
