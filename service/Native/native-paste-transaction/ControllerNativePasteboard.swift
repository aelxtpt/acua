import AppKit
import Foundation

final class ControllerNativePasteDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    typealias Instant = SuspendingClock.Instant
    private let values: [String:Data]
    private let started: @Sendable (Instant) -> Void
    private let finished: @Sendable (Instant, Instant, Bool) -> Void
    private let lock = NSLock()
    private var failed = false
    let reads: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    @MainActor let rearming: ControllerPasteboardRearming<NSPasteboardItem>
    @MainActor private let pasteboard: NSPasteboard
    @MainActor init(values: [ControllerPasteRepresentation], pasteboard: NSPasteboard,
                    started: @escaping @Sendable (Instant) -> Void,
                    finished: @escaping @Sendable (Instant, Instant, Bool) -> Void) {
        self.values = Dictionary(values.map { ($0.type,$0.data) }, uniquingKeysWith: { _,last in last })
        self.pasteboard = pasteboard; self.started = started; self.finished = finished
        (reads,continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        rearming = .init()
        super.init()
    }
    var failedToProvideData: Bool { lock.withLock { failed } }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        ControllerPasteDataDelivery(now: { SuspendingClock.now }, started: started,
            representation: { self.values[$0] }, setData: { item.setData($0, forType: .init($1)) },
            markFailed: { self.lock.withLock { self.failed = true } }, finished: finished,
            yieldRead: { self.continuation.yield() }, enqueueRearm: { [self] type in
                DispatchQueue.main.async { [weak self] in self?.rearm(type) }
            }).provide(type.rawValue)
    }
    @MainActor private func rearm(_ type: String) {
        rearming.rearm(type: type, generation: { self.pasteboard.changeCount }, setProvider: { item,type in
            _ = item.setDataProvider(self, forTypes: [.init(type)])
        })
    }
}

@MainActor struct ControllerNativePasteboardBackend: ControllerPasteboardBackend {
    typealias Item = NSPasteboardItem
    typealias Provider = ControllerNativePasteDataProvider
    let pasteboard: NSPasteboard
    let readStarted: @Sendable (SuspendingClock.Instant) -> Void
    let readFinished: @Sendable (SuspendingClock.Instant, SuspendingClock.Instant, Bool) -> Void
    let logOwnershipLost: @MainActor () -> Void
    func makeProvider(_ values: [ControllerPasteRepresentation]) -> Provider {
        .init(values: values, pasteboard: pasteboard, started: readStarted, finished: readFinished)
    }
    func makeItem() -> Item { .init() }
    func setProvider(_ provider: Provider, on item: Item, types: [String]) -> Bool {
        item.setDataProvider(provider, forTypes: types.map { NSPasteboard.PasteboardType($0) })
    }
    func items() -> [Item]? { pasteboard.pasteboardItems }
    func types(_ item: Item) -> [String] { item.types.map(\.rawValue) }
    func data(_ item: Item, type: String) -> Data? { item.data(forType: .init(type)) }
    func prepareCurrentHostOnly() -> Int { pasteboard.prepareForNewContents(with: .currentHostOnly) }
    func arm(_ provider: Provider, item: Item, generation: Int) { provider.rearming.arm(item: item, generation: generation) }
    func clearRearming(_ provider: Provider) { provider.rearming.clear() }
    func generation() -> Int { pasteboard.changeCount }
    func write(_ items: [Item]) -> Bool { pasteboard.writeObjects(items) }
    func clearContents() { pasteboard.clearContents() }
    func setData(_ data: Data, type: String, item: Item) { _ = item.setData(data, forType: .init(type)) }
    func ownershipLost() { logOwnershipLost() }
}
