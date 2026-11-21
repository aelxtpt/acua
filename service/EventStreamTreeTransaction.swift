import Foundation
import ApplicationServices

// Immutable capture records and the existing locked fallback cache can be
// inherited through TaskLocal. All AX reads and node access remain MainActor.
struct EventStreamNativeTreeTransaction: @unchecked Sendable {
    typealias Identity = EventStreamSnapshotAXIdentity
    let root:AXUIElement
    let snapshots:EventStreamNativeSnapshots.Transaction
    let partialValues:EventStreamHierarchyCapture.Table
    let roleFrequency:[String:Int]
}

enum EventStreamTreeTransactions {
    @TaskLocal static var current:EventStreamNativeTreeTransaction?
    @TaskLocal static var prefetchEnabled=true
}

@MainActor struct EventStreamNativeTransactions {
    let snapshots:EventStreamNativeSnapshots
    let hierarchy:EventStreamHierarchyCapture?
    private let supported:(AXUIElement)->Set<String>
    private let bundle:(AXUIElement)->String?
    init(snapshots:EventStreamNativeSnapshots? = nil,hierarchy:EventStreamHierarchyCapture? = nil,
         supportedAttributes:((AXUIElement)->Set<String>)? = nil,bundleIdentifier:((AXUIElement)->String?)? = nil) {
        let reader=snapshots ?? EventStreamNativeSnapshots();self.snapshots=reader
        self.supported=supportedAttributes ?? {reader.backend.supportedAttributes(of:.init(element:$0))}
        self.bundle=bundleIdentifier ?? {reader.backend.bundleIdentifier(of:.init(element:$0))}
        if let hierarchy {self.hierarchy=hierarchy}
        else if let keys=EventStreamHierarchySPI.keys,EventStreamHierarchySPI.available {
            self.hierarchy = .init(keys:keys,copy:EventStreamHierarchySPI.copy)
        } else {self.hierarchy=nil}
    }
    // The hierarchy requests common attributes for every element,
    // selected relations, supplied additions and the root's bundle exclusion.
    func capture(_ root:AXUIElement,additionalAttributes:[String]=[],maximumChildCount:Int=100) -> EventStreamNativeTreeTransaction {
        var table:EventStreamHierarchyCapture.Table = [:],requested:Set<String> = []
        if EventStreamTreeTransactions.prefetchEnabled {
            var attributes=EventStreamSnapshotAttributes.common.union(["AXSelectedRows","AXSelectedCells","AXSelectedChildren"])
            attributes.formUnion(additionalAttributes)
            if supported(root).contains("AXDOMClassList"),!attributes.contains("AXDOMClassList"),
               bundle(root)=="com.kishanbagaria.jack" {attributes.insert("AXDOMClassList")}
            let traversal=["AXChildren"]
            table=hierarchy?.capture(root,traversal:traversal,attributes:Array(attributes),maximumArrayCount:maximumChildCount) ?? [:]
            requested=attributes.union(traversal)
        }
        let raw=table.mapValues {$0.mapValues(\.value)}
        var frequencies:[String:Int] = [:]
        for values in raw.values {if let role=values["AXRole"] as? String {frequencies[role,default:0] += 1}}
        let transaction=EventStreamNativeTreeTransaction(root:root,
            snapshots:.init(attributeTable:raw,requestedAttributes:requested),partialValues:table,roleFrequency:frequencies)
        // Construct the root UIElement while creating the
        // transaction, filling fallback even when prefetch returns no root.
        _ = snapshots.capture(root,transaction:transaction.snapshots)
        return transaction
    }
    // Reuse the receiver when the active prefetch table contains
    // it; with prefetch disabled, any active transaction is reused. Additional
    // requests/budgets do not invalidate a reusable active transaction.
    func withSubtree<Result>(_ receiver:EventStreamAXNode,additionalAttributes:[String]=[],maximumChildCount:Int=100,
                             perform:(EventStreamAXNode) throws -> Result) rethrows -> Result {
        if let current=EventStreamTreeTransactions.current,
           !EventStreamTreeTransactions.prefetchEnabled || current.snapshots.attributeTable[.init(element:receiver.element)] != nil {
            return try perform(receiver)
        }
        let transaction=capture(receiver.element,additionalAttributes:additionalAttributes,maximumChildCount:maximumChildCount)
        return try EventStreamTreeTransactions.$current.withValue(transaction) {
            try perform(snapshots.node(transaction.root))
        }
    }
}
