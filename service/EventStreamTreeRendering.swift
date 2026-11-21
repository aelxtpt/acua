import Foundation

struct EventStreamRenderLineOptions: OptionSet {
    let rawValue: UInt8
    static let withoutElementID = Self(rawValue: 1)
    static let withoutDetailText = Self(rawValue: 2)
    static let withoutInsertionSubtree = Self(rawValue: 4)
    static let withoutRemovalSubtree = Self(rawValue: 8)
}

// A render tree is a forest of already transformed nodes, not an AX capture.
// IDs and descriptions belong to the EventStream lineage supplied by its
// extractor; they are never borrowed from the automation session's IDs.
struct EventStreamRenderNode {
    var id: Int?
    var description: String
    var detail: String?
    var children: [Self] = []

    // UIElementRender.line, 0x100648C1C. Empty (present) details retain the space.
    func line(indent: Character = "\t", depth: Int = 0, options: EventStreamRenderLineOptions = []) -> String {
        var text = description
        if !options.contains(.withoutDetailText), let detail { text += " " + detail }
        if !options.contains(.withoutElementID), let id { text = "\(id) " + text }
        return String(repeating: indent, count: depth) + text
    }
}

enum EventStreamTreeRendering {
    // UIElementRenderTree.lines, 0x100648A58. Root depth is zero; depth-first
    // preorder keeps the forest and child order. No automation depth clamp.
    static func lines(_ roots: [EventStreamRenderNode], indent: Character = "\t",
                      options: EventStreamRenderLineOptions = []) -> [String] {
        var pending = roots.reversed().map { (node: $0, depth: 0) }, result: [String] = []
        while let current = pending.popLast() {
            result.append(current.node.line(indent: indent, depth: current.depth, options: options))
            pending.append(contentsOf: current.node.children.reversed().map { ($0, current.depth + 1) })
        }
        return result
    }

    // Final serialization from 0x100242A14. A nil difference means unavailable
    // and requires the full forest; an available empty difference is no_change.
    // Calculating differences still requires the native revision/diff backend.
    static func description(_ roots: [EventStreamRenderNode], differenceLines: [String]?,
                            options: EventStreamRenderLineOptions = []) -> String {
        if let differenceLines {
            return differenceLines.isEmpty ? "no_change" : differenceLines.joined(separator: "\n")
        }
        return lines(roots, options: options).joined(separator: "\n")
    }
}
