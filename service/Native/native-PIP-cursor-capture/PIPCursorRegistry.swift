import Foundation

@MainActor protocol PIPCaptureCursor: AnyObject {
    var pipTargetWindowID: UInt32? { get }
    var pipIsVisible: Bool { get }
    var pipWindowNumber: Int { get }
}

/// Weak NSHashTable, preserving native allObjects order.
@MainActor final class PIPCursorRegistry {
    static let shared=PIPCursorRegistry()
    static let didFinishMove=Notification.Name("computerUseCursorDidFinishMove")
    private let table=NSHashTable<AnyObject>.weakObjects()
    func add(_ cursor:any PIPCaptureCursor) { table.add(cursor) }
    var allObjects:[any PIPCaptureCursor] { table.allObjects.compactMap { $0 as? any PIPCaptureCursor } }
    static func notificationMatches(_ object:Any?,windowID:UInt32) -> Bool {
        guard let cursor=object as? any PIPCaptureCursor else { return false }
        return cursor.pipTargetWindowID==windowID && cursor.pipIsVisible
    }
}
