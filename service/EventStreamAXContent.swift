import Foundation

// Title and text extraction for recorded accessibility elements. Node access is injected so the same extraction runs against cached native AX
// nodes and deterministic fixtures, without recording user input in tests.
@MainActor
struct EventStreamAXContent<Node> {
    let string: (Node, String) -> String?
    let numberOfCharacters: (Node) -> Int?
    let visibleRange: (Node) -> NSRange?
    let stringForRange: (Node, NSRange) -> String?
    let children: (Node, Int) -> [Node]
    private static var titleAttributes: [String] { ["AXTitle", "AXDescription", "AXValue", "AXValueDescription", "AXPlaceholderValue"] }
    private static var textRoles: Set<String> { ["AXTextArea", "AXTextField", "AXStaticText"] }
    static var truncationPrefix: String { "[truncated to visible range] " }

    func directTitle(_ node: Node) -> String? {
        // All five values are accessed before selecting (including the
        // unbounded value), so every cached node attribute is read.
        Self.titleAttributes.map { string(node, $0)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { $0 }.first { !$0.isEmpty }
    }

    func title(_ node: Node) -> String? {
        if let title = directTitle(node) { return title }
        return descendantTitle(node)
    }

    func descendantTitle(_ node: Node) -> String? {
        var queue = children(node, 8).prefix(8).map { ($0, 1) }
        var index = 0, labels: [String] = []
        while index < queue.count && labels.count < 6 {
            let (current, depth) = queue[index]
            index += 1
            if let label = directTitle(current), !labels.contains(label) { labels.append(label) }
            if depth <= 2 {
                queue.append(contentsOf: children(current, 8).prefix(8).map { ($0, depth + 1) })
            }
        }
        return labels.isEmpty ? nil : labels.joined(separator: " ")
    }

    func value(_ node: Node) -> String? {
        guard let value = string(node, "AXValue"), !value.isEmpty else { return nil }
        guard Self.textRoles.contains(string(node, "AXRole") ?? "AXUnknown") else { return value }
        let native = value as NSString
        let total = max(native.length, numberOfCharacters(node) ?? 0)
        guard total > 1000 else { return value }
        let range: NSRange
        if let visible = visibleRange(node), visible.location >= 0, visible.location < total, visible.length > 0 {
            range = NSRange(location: visible.location, length: min(1000, visible.length, total - visible.location))
        } else {
            range = NSRange(location: 0, length: 1000)
        }
        if let visible = stringForRange(node, range), !visible.isEmpty {
            return Self.truncationPrefix + visible
        }
        let location = min(native.length, range.location)
        let length = min(native.length - location, range.length)
        guard length > 0 else { return nil }
        return Self.truncationPrefix + native.substring(with: NSRange(location: location, length: length))
    }

    func describe(_ node: Node) -> EventStreamAXElement {
        describe(node, title: title(node))
    }

    // Endpoint title: raw nonempty AXTitle, derived cell label, then
    // clicked-row label override. Unlike focused-element titles, do not use
    // this node's description/value as a generic fallback.
    func describeEndpoint(_ node: Node, titleOverride: String?) -> EventStreamAXElement {
        let title = nonempty(string(node, "AXTitle"))
            ?? (string(node, "AXRole") == "AXCell" ? descendantTitle(node) : nil)
            ?? titleOverride
        return describe(node, title: title)
    }

    private func describe(_ node: Node, title: String?) -> EventStreamAXElement {
        EventStreamAXElement(role: string(node, "AXRole") ?? "AXUnknown", subrole: string(node, "AXSubrole"),
            title: title, description: nonempty(string(node, "AXDescription")), value: value(node),
            placeholder: nonempty(string(node, "AXPlaceholderValue")), identifier: nonempty(string(node, "AXIdentifier")))
    }

    private func nonempty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
}
