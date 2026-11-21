import Foundation

struct ControllerPasteRepresentation: Sendable, Equatable { let type: String; let data: Data }
typealias ControllerPasteboardSnapshot = [[String: Data]]
enum ControllerPasteboardFailure: Error, Equatable { case failedToProvideData }

@MainActor protocol ControllerPasteboardBackend {
    associatedtype Item
    associatedtype Provider
    func makeProvider(_ values: [ControllerPasteRepresentation]) -> Provider
    func makeItem() -> Item
    func setProvider(_ provider: Provider, on item: Item, types: [String]) -> Bool
    func items() -> [Item]?
    func types(_ item: Item) -> [String]
    func data(_ item: Item, type: String) -> Data?
    func prepareCurrentHostOnly() -> Int
    func arm(_ provider: Provider, item: Item, generation: Int)
    func clearRearming(_ provider: Provider)
    func generation() -> Int
    func write(_ items: [Item]) -> Bool
    func clearContents()
    func setData(_ data: Data, type: String, item: Item)
    func ownershipLost()
}

@MainActor struct ControllerPasteboardTransaction<Backend: ControllerPasteboardBackend> {
    @MainActor final class Session {
        let snapshot: ControllerPasteboardSnapshot?
        let provider: Backend.Provider
        let generation: Int
        init(snapshot: ControllerPasteboardSnapshot?, provider: Backend.Provider, generation: Int) {
            self.snapshot = snapshot; self.provider = provider; self.generation = generation
        }
    }
    let backend: Backend
    /// Preserves nil versus present-empty and drops unreadable types.
    func snapshot() -> ControllerPasteboardSnapshot? {
        backend.items().map { items in items.map { item in
            var values: [String:Data] = [:]
            for type in backend.types(item) { values[type] = backend.data(item, type: type) }
            return values
        } }
    }
    /// Provider setup precedes snapshot and any clipboard mutation.
    func prepare(_ values: [ControllerPasteRepresentation]) throws -> Session {
        let provider = backend.makeProvider(values), item = backend.makeItem()
        guard backend.setProvider(provider, on: item, types: values.map(\.type)) else {
            throw ControllerPasteboardFailure.failedToProvideData
        }
        let saved = snapshot(), generation = backend.prepareCurrentHostOnly()
        backend.arm(provider, item: item, generation: generation)
        let session = Session(snapshot: saved, provider: provider, generation: generation)
        guard backend.write([item]) else {
            _ = restore(session)
            throw ControllerPasteboardFailure.failedToProvideData
        }
        return session
    }
    /// Returns generation ownership, not the result of restoring bytes.
    /// Uses clearContents and ignores setData/writeObjects return values.
    @discardableResult func restore(_ session: Session) -> Bool {
        backend.clearRearming(session.provider)
        guard backend.generation() == session.generation else { backend.ownershipLost(); return false }
        backend.clearContents()
        if let saved = session.snapshot {
            let items = saved.map { values in
                let item = backend.makeItem()
                for (type,data) in values { backend.setData(data, type: type, item: item) }
                return item
            }
            _ = backend.write(items)
        }
        return true
    }
}

/// Keep the retained pre-query tuple across potentially reentrant calls.
@MainActor final class ControllerPasteboardRearming<Item> {
    struct State { let item: Item; let generation: Int; var count: Int }
    private(set) var state: State?
    func arm(item: Item, generation: Int, count: Int = 0) { state = .init(item: item, generation: generation, count: count) }
    func clear() { state = nil }
    func rearm(type: String, generation: () -> Int, setProvider: (Item, String) -> Void) {
        guard let captured = state else { return }
        guard generation() == captured.generation else { clear(); return }
        guard captured.count <= 255 else { return }
        if state != nil { state!.count += 1 }
        setProvider(captured.item, type)
        if generation() != captured.generation { clear() }
    }
}
