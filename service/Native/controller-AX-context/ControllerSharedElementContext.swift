import Foundation

// This immutable identity contains one retained CF AX reference. Equality/hash
// use CF identity, matching the existing sendable SettingsNativeAXElement.
extension EventStreamSnapshotAXIdentity: @unchecked Sendable {}

extension ControllerNativeElementContext {
    /// Both controller and existing tree readers consult the SAME TaskLocal and
    /// locked fallback cache. There is no second production transaction slot.
    static func shared(lookup: @escaping @Sendable (SettingsNativeAXElement) -> CachedIdentity?,
                       log: @escaping @Sendable (String, any Error) -> Void) -> Self {
        .init(currentTransaction: {
            guard let transaction = EventStreamTreeTransactions.current else { return nil }
            return .bridged(transaction.snapshots, rootKey: { .init(element: $0.element) })
        }, lookup: lookup, log: log)
    }
}
