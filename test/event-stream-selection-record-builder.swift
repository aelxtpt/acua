import Foundation

@main struct Tests {
    @MainActor static func main() async {
        var checks = 0
        func check(_ label: String, _ condition: @autoclosure () -> Bool) {
            precondition(condition(), "FAIL: \(label)"); checks += 1; print("PASS: \(label)")
        }
        typealias Builder = EventStreamSelectionRecordBuilder<Int>
        var trace: [String] = [], sequence = 0
        var range: EventStreamTextRange? = .init(location: 4, length: 2)
        var text: String? = "ab"
        var app: EventStreamApp? = .init(name: "App", secureInput: false, processIdentifier: 10, bundleIdentifier: "bundle")
        var window: EventStreamWindow? = .init(title: "Window", url: "https://example.test", windowID: 11)
        var target: EventStreamAXElement? = .init(role: "AXTextField", subrole: "sub", title: "Title", description: "Description", value: "Value", placeholder: "Placeholder", identifier: "ID")
        var items: [EventStreamAXElement]? = [.init(role: "AXRow", title: "First"), .init(role: "AXRow", title: "Second")]
        var failItems = false
        enum Failure: Error { case items }
        let builder = Builder(backend: .init(selectedRange: { node in trace.append("range:\(node)"); return range },
            selectedText: { node in trace.append("text:\(node)"); return text },
            application: { node in trace.append("app:\(node)"); return app },
            window: { node in trace.append("window:\(node)"); return window },
            target: { node in trace.append("target:\(node)"); return target },
            selectedItems: { node, attribute, maximum in
                trace.append("items:\(node):\(attribute):\(maximum)")
                if failItems { throw Failure.items }; return items
            }, nextIdentity: {
                trace.append("identity"); sequence += 1
                return .init(id: sequence, timestamp: Date(timeIntervalSince1970: Double(sequence)))
            }, notificationDescription: { name in trace.append("description"); return "native(\(name))" }))
        func make(_ name: String = "AXSelectedTextChanged", node: Int = 1) -> EventStreamPendingSelectionRecord? {
            trace = []; return builder.make(element: node, notification: name)
        }
        let first = make()!
        check("text selection reads range text context and target before identity", trace == ["range:1", "text:1", "app:1", "window:1", "target:1", "identity", "description"])
        check("text selection emits selected range text and empty items", first.record.selection == .init(target: target, selectedText: "ab", selectedRange: range, selectedItems: []))
        check("record retains captured app and window metadata", first.record.app == app && first.record.window == window)
        check("selection record has no AX mouse keyboard or diagnostic", first.record.kind == .selectionChanged && first.record.ax == nil && first.record.mouse == nil && first.record.keyboard == nil && first.record.diagnostic == nil)
        check("text key uses supplied native notification description", first.key == "App|Window|native(AXSelectedTextChanged)")
        check("identity is allocated by current shared source", first.record.id == 1 && first.record.timestamp == Date(timeIntervalSince1970: 1))
        let before = sequence
        range = .init(location: 4, length: 0)
        check("present zero selection range suppresses even nonempty text", make() == nil && trace == ["range:1"] && sequence == before)
        range = .init(location: 4, length: -1)
        check("negative range length is suppressed before text lookup", make() == nil && trace == ["range:1"] && sequence == before)
        range = nil; text = nil
        check("missing range and text is suppressed without context or identity", make() == nil && trace == ["range:1", "text:1"] && sequence == before)
        text = ""
        check("empty selected text alone does not emit", make() == nil && sequence == before)
        text = " \n "
        check("whitespace selected text without range is preserved", make()?.record.selection?.selectedText == " \n ")
        text = nil; range = .init(location: 8, length: 3)
        let rangeOnly = make()!
        check("positive range with no text still emits", rangeOnly.record.selection?.selectedText == nil && rangeOnly.record.selection?.selectedRange == range)
        text = ""; check("empty selected text becomes nil with positive range", make()?.record.selection?.selectedText == nil)
        text = "value"; range = .init(location: -3, length: 1)
        check("range location is forwarded without an added positivity check", make()?.record.selection?.selectedRange?.location == -3)
        range = .init(location: Int.max, length: Int.max)
        check("range is forwarded without unused overflow-prone end arithmetic", make()?.record.selection?.selectedRange == range)
        let mappings = [("AXSelectedRowsChanged", "AXSelectedRows"), ("AXSelectedColumnsChanged", "AXSelectedColumns"), ("AXSelectedCellsChanged", "AXSelectedCells"), ("AXSelectedChildrenChanged", "AXSelectedChildren"), ("AXSelectedChildrenMoved", "AXSelectedChildren")]
        for (notification, attribute) in mappings {
            let pending = make(notification)!
            check("\(notification) requests correct attribute with maximum12", trace == ["app:1", "window:1", "target:1", "items:1:\(attribute):12", "identity", "description"] && pending.record.selection?.selectedItems == items)
        }
        let rows = make("AXSelectedRowsChanged")!
        check("item selection omits text and range", rows.record.selection?.selectedText == nil && rows.record.selection?.selectedRange == nil)
        check("nontext key uses descriptor fields in fixed order", rows.key == "App|Window|native(AXSelectedRowsChanged)|AXTextField|sub|ID|Title|Description|Placeholder")
        check("selected item order is preserved", rows.record.selection?.selectedItems.map(\.title) == ["First", "Second"])
        failItems = true
        check("item read error still emits selection with empty items", make("AXSelectedRowsChanged")?.record.selection?.selectedItems == [])
        failItems = false; items = nil
        check("missing items still emits an empty selection", make("AXSelectedCellsChanged")?.record.selection?.selectedItems == [])
        items = []
        check("empty item selection is not suppressed", make("AXSelectedChildrenChanged") != nil)
        let unknownBefore = sequence
        check("unrelated notification performs no reads", make("AXValueChanged") == nil && trace.isEmpty && sequence == unknownBefore)
        check("focused-window notification is handled by another path", make("AXFocusedWindowChanged") == nil && trace.isEmpty)
        check("notification classification is exact", make("axselectedtextchanged") == nil && trace.isEmpty)
        let keyBeforeValue = make("AXSelectedRowsChanged")!.key
        target?.value = "Changed"
        check("target value is excluded from coalescing key", make("AXSelectedRowsChanged")!.key == keyBeforeValue)
        let textKey = make()!.key
        target?.identifier = "Different"
        check("text selection key excludes target descriptor", make()!.key == textKey)
        check("item selection key distinguishes target identifier", make("AXSelectedRowsChanged")!.key != keyBeforeValue)
        app = nil; window = nil; target = nil
        let nameless = make("AXSelectedRowsChanged")!
        check("missing context and target still yields item selection", nameless.record.app == nil && nameless.record.window == nil && nameless.record.selection?.target == nil)
        check("missing nontext context preserves empty key components", nameless.key == "||native(AXSelectedRowsChanged)|")
        check("missing text context key does not add target separator", make()!.key == "||native(AXSelectedTextChanged)")
        let blank = EventStreamAXElement()
        check("present empty target retains six key fields", Builder.targetKey(blank) == "|||||")
        check("absent target yields an empty key suffix", Builder.targetKey(nil) == "")
        var keyed = EventStreamAXElement(role: "r", subrole: "s", title: "t", description: "d", value: "v", placeholder: "p", identifier: "i")
        check("descriptor key is role subrole identifier title description placeholder", Builder.targetKey(keyed) == "r|s|i|t|d|p")
        keyed.title = "  title  "
        check("key retains descriptor whitespace", Builder.targetKey(keyed) == "r|s|i|  title  |d|p")
        app = .init(name: "A|B", secureInput: false); window = .init(title: "C")
        let collision = make()!.key
        app = .init(name: "A", secureInput: false); window = .init(title: "B|C")
        check("unescaped key delimiter collisions are preserved", make()!.key == collision)
        var delivered: [EventStreamRecord] = []
        let queue = EventStreamAXNotificationQueue(isRecording: { true }, sleep: { try await ContinuousClock().sleep(for: $0) }, emit: { delivered.append($0) })
        app = .init(name: "App", secureInput: false); window = .init(title: "Window")
        target = .init(role: "AXTextField", identifier: "one")
        let pending1 = make(node: 1)!
        target?.identifier = "two"
        let pending2 = make(node: 2)!
        queue.enqueue(pending1.record, key: pending1.key, notification: pending1.notification)
        queue.enqueue(pending2.record, key: pending2.key, notification: pending2.notification)
        check("text notifications from different targets share one key", pending1.key == pending2.key && queue.pendingCount == 1)
        app?.name = "Later"; window?.title = "Later"; target?.identifier = "Later"
        queue.flushPendingRecords()
        check("queue integration keeps newest complete payload", delivered == [pending2.record])
        check("queued selection metadata does not refresh before flush", delivered.last?.app?.name == "App" && delivered.last?.window?.title == "Window" && delivered.last?.selection?.target?.identifier == "two")
        app?.name = "App"; window?.title = "Window"; target?.identifier = "one"
        let item1 = make("AXSelectedRowsChanged")!
        target?.identifier = "two"
        let item2 = make("AXSelectedRowsChanged")!
        queue.enqueue(item1.record, key: item1.key, notification: item1.notification)
        queue.enqueue(item2.record, key: item2.key, notification: item2.notification)
        check("different item descriptors remain independently pending", item1.key != item2.key && queue.pendingCount == 2)
        queue.flushPendingRecords()
        check("item queue integration preserves both supplied identities", Set(delivered.suffix(2).map(\.id)) == [item1.record.id, item2.record.id])
        queue.cancelPendingRecords()
        for _ in 0..<20 { await Task.yield() }
        check("integration releases all pending tasks", queue.scheduledCount == 0 && queue.pendingCount == 0)
        print("\(checks) checks")
    }
}
