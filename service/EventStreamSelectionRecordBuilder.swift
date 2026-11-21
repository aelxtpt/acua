import Foundation

struct EventStreamPendingSelectionRecord {
    let key: String
    let notification: String
    let record: EventStreamRecord
}

// Selection construction, item projection and notification key. This does
// not install native observers.
@MainActor
struct EventStreamSelectionRecordBuilder<Node> {
    struct Backend {
        var selectedRange: (Node) -> EventStreamTextRange?
        var selectedText: (Node) -> String?
        var application: (Node) -> EventStreamApp?
        var window: (Node) -> EventStreamWindow?
        var target: (Node) -> EventStreamAXElement?
        var selectedItems: (Node, String, Int) throws -> [EventStreamAXElement]?
        var nextIdentity: () -> EventStreamRecordIdentity
        // The key uses String(describing: AXNotification). Native binding must
        // supply that representation; classification still uses the raw name.
        var notificationDescription: (String) -> String
    }
    let backend: Backend

    func make(element: Node, notification: String) -> EventStreamPendingSelectionRecord? {
        let textSelection = notification == "AXSelectedTextChanged"
        let attribute = Self.selectedAttribute(notification)
        guard textSelection || attribute != nil else { return nil }
        var selectedRange: EventStreamTextRange?
        var selectedText: String?
        if textSelection {
            selectedRange = backend.selectedRange(element)
            // A present empty range suppresses the event before reading text.
            if let selectedRange, selectedRange.length <= 0 { return nil }
            selectedText = backend.selectedText(element).flatMap { $0.isEmpty ? nil : $0 }
            guard selectedRange != nil || selectedText != nil else { return nil }
        }
        let app = backend.application(element)
        let window = backend.window(element)
        let target = backend.target(element)
        var items: [EventStreamAXElement] = []
        if let attribute { items = (try? backend.selectedItems(element, attribute, 12)) ?? [] }
        let identity = backend.nextIdentity()
        let selection = EventStreamSelection(target: target, selectedText: selectedText,
                                             selectedRange: selectedRange, selectedItems: items)
        let record = EventStreamRecord(id: identity.id, timestamp: identity.timestamp,
            kind: .selectionChanged, app: app, window: window, selection: selection)
        let description = backend.notificationDescription(notification)
        let base = [app?.name ?? "", window?.title ?? "", description].joined(separator: "|")
        let key = textSelection ? base : base + "|" + Self.targetKey(target)
        return .init(key: key, notification: notification, record: record)
    }

    static func selectedAttribute(_ notification: String) -> String? {
        switch notification {
        case "AXSelectedRowsChanged": return "AXSelectedRows"
        case "AXSelectedColumnsChanged": return "AXSelectedColumns"
        case "AXSelectedCellsChanged": return "AXSelectedCells"
        case "AXSelectedChildrenChanged", "AXSelectedChildrenMoved": return "AXSelectedChildren"
        default: return nil
        }
    }

    static func targetKey(_ target: EventStreamAXElement?) -> String {
        guard let target else { return "" }
        return [target.role, target.subrole, target.identifier, target.title,
                target.description, target.placeholder].map { $0 ?? "" }.joined(separator: "|")
    }
}
