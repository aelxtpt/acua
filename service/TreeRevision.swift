import Foundation

struct ElementFrame: Hashable {
    let x: Double, y: Double, width: Double, height: Double
    var rendered: String? {
        let values = [x, y, width, height].compactMap { Int(exactly: $0.rounded(.towardZero)) }
        guard values.count == 4, width >= 0, height >= 0 else { return nil }
        return values.map(String.init).joined(separator: ",")
    }
}

struct ElementDescription: Hashable {
    var role: String
    var subrole: String? = nil
    var identifier: String? = nil
    var title: String? = nil
    var value: String? = nil
    var detail: String? = nil
    var help: String? = nil
    var url: String? = nil
    var enabled: Bool? = nil
    var actions: [String] = []
    var frame: ElementFrame? = nil

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    var hasSemanticIdentity: Bool {
        [identifier, title, detail, help, value, url].contains { !($0 ?? "").isEmpty }
    }

    func fingerprint(ignoreValue: Bool = false) -> ElementDescription {
        var copy = self
        copy.frame = nil
        copy.actions.sort()
        if ignoreValue { copy.value = nil }
        return copy
    }

    func line(id: Int, depth: Int, includeElementID: Bool = true) -> String {
        let elementPrefix = includeElementID ? "[\(id)] " : ""
        var parts = [String(repeating: "  ", count: min(depth + 1, 12)) + elementPrefix + "\(Self.escape(role))"]
        for (name, value) in [("title", title), ("value", value), ("desc", detail), ("help", help), ("url", url)] {
            if let value, !value.isEmpty { parts.append("\(name)=\"\(Self.escape(value))\"") }
        }
        if let subrole, !subrole.isEmpty { parts.append("subrole=\(Self.escape(subrole))") }
        if let identifier, !identifier.isEmpty { parts.append("id=\(Self.escape(identifier))") }
        if let enabled { parts.append("enabled=\(enabled)") }
        if !actions.isEmpty { parts.append("actions=[\(actions.map(Self.escape).joined(separator: ","))]") }
        if let rendered = frame?.rendered { parts.append("frame=(\(rendered))") }
        return parts.joined(separator: " ")
    }
}

struct TreeSection: Equatable {
    let key: String
    let title: String
    var opening: String { "<app window=\"\(ElementDescription.escape(title))\">" }
}

struct TreeNode<Reference: Hashable> {
    let reference: Reference
    let description: ElementDescription
    let parent: Int?
    let section: String
}

struct TreeEntry<Reference: Hashable> {
    let id: Int
    let reference: Reference
    let description: ElementDescription
    let parentID: Int?
    let section: String
    let depth: Int
    let predecessorID: Int?
    var line: String { description.line(id: id, depth: depth) }
}

struct TreeChange<Reference: Hashable> {
    enum Kind { case inserted, modified, moved, removed }
    let kind: Kind
    let before: TreeEntry<Reference>?
    let after: TreeEntry<Reference>?
}

struct TreeRevision<Reference: Hashable> {
    let session: String
    let number: Int
    let sections: [TreeSection]
    let entries: [TreeEntry<Reference>]
    let changes: [TreeChange<Reference>]
    let fullText: String
    let text: String
    let isDiff: Bool
    let truncated: Bool
    func entry(_ id: Int) -> TreeEntry<Reference>? { entries.first { $0.id == id } }

    func validatedElement(expected: TreeEntry<Reference>, ignoreValueChange: Bool = false) throws -> TreeEntry<Reference> {
        guard let candidate = entry(expected.id),
              candidate.description.fingerprint(ignoreValue: ignoreValueChange) == expected.description.fingerprint(ignoreValue: ignoreValueChange) else {
            throw ServiceError(.accessibilityError, "Control changed or disappeared; read app state again")
        }
        if candidate.reference != expected.reference {
            let matches = entries.filter {
                $0.section == expected.section && $0.parentID == expected.parentID &&
                $0.description.fingerprint(ignoreValue: ignoreValueChange) == expected.description.fingerprint(ignoreValue: ignoreValueChange)
            }
            guard !truncated, matches.count == 1 else {
                throw ServiceError(.accessibilityError, "Control recovery is ambiguous or incomplete; read app state again")
            }
        }
        return candidate
    }
}

/// Owns IDs for a lineage of observations. Update is transactional: cancellation,
/// malformed input or counter exhaustion cannot leave a half-written revision.
struct TreeRevisionStore<Reference: Hashable> {
    private(set) var current: TreeRevision<Reference>?
    private(set) var nextID: Int
    private var revisionNumber = 0

    init(nextID: Int = 0) { self.nextID = nextID }
    mutating func invalidate() { current = nil }

    private struct MatchKey: Hashable {
        let parent: Int?
        let section: String
        let description: ElementDescription
    }
    private struct ParentKey: Hashable { let id: Int?; let section: String }

    private func key(_ description: ElementDescription, parent: Int?, section: String) -> MatchKey? {
        guard description.hasSemanticIdentity else { return nil }
        let content: ElementDescription
        if let id = description.identifier, !id.isEmpty {
            content = ElementDescription(role: description.role, subrole: description.subrole, identifier: id)
        } else { content = description.fingerprint() }
        return MatchKey(parent: parent, section: section, description: content)
    }

    mutating func update(session: String, sections: [TreeSection], nodes: [TreeNode<Reference>],
                         appName: String, forceFull: Bool = false, truncated: Bool = false,
                         maxDiffLines: Int = 200, check: () throws -> Void = {}) throws -> TreeRevision<Reference> {
        try check()
        let sectionKeys = Set(sections.map(\.key))
        guard sectionKeys.count == sections.count, nextID >= 0, revisionNumber < Int.max else {
            throw ServiceError(.accessibilityError, "Invalid tree lineage")
        }
        var references = Set<Reference>(), depths: [Int] = []
        for (index, node) in nodes.enumerated() {
            try check()
            guard references.insert(node.reference).inserted, sectionKeys.contains(node.section) else {
                throw ServiceError(.accessibilityError, "Duplicate or unscoped accessibility element")
            }
            if let parent = node.parent {
                guard parent >= 0, parent < index, nodes[parent].section == node.section else {
                    throw ServiceError(.accessibilityError, "Invalid accessibility parent")
                }
                depths.append(depths[parent] + 1)
            } else { depths.append(0) }
        }
        let previous = current?.session == session ? current : nil
        let old = previous?.entries ?? []
        let oldByReference = Dictionary(uniqueKeysWithValues: old.map { ($0.reference, $0) })
        var assigned = [Int?](repeating: nil, count: nodes.count)
        var used = Set<Int>()
        for (index, node) in nodes.enumerated() {
            if let entry = oldByReference[node.reference], entry.section == node.section,
               entry.description.role == node.description.role,
               entry.description.subrole == node.description.subrole,
               entry.description.identifier == node.description.identifier {
                assigned[index] = entry.id; used.insert(entry.id)
            }
        }
        var candidateNext = nextID
        for depth in 0...(depths.max() ?? 0) {
            try check()
            let level = nodes.indices.filter { depths[$0] == depth && assigned[$0] == nil }
            var oldGroups: [MatchKey: [Int]] = [:], newGroups: [MatchKey: [Int]] = [:]
            for entry in old where !used.contains(entry.id) {
                if let key = key(entry.description, parent: entry.parentID, section: entry.section) {
                    oldGroups[key, default: []].append(entry.id)
                }
            }
            for index in level {
                let node = nodes[index], parent = node.parent.flatMap { assigned[$0] }
                if let key = key(node.description, parent: parent, section: node.section) {
                    newGroups[key, default: []].append(index)
                }
            }
            for index in level {
                let node = nodes[index], parent = node.parent.flatMap { assigned[$0] }
                if let key = key(node.description, parent: parent, section: node.section),
                   oldGroups[key]?.count == 1, newGroups[key]?.count == 1, let id = oldGroups[key]?.first {
                    assigned[index] = id; used.insert(id)
                } else {
                    guard candidateNext < Int.max else { throw ServiceError(.accessibilityError, "Accessibility ID space exhausted") }
                    assigned[index] = candidateNext; used.insert(candidateNext); candidateNext += 1
                }
            }
        }
        var entries: [TreeEntry<Reference>] = [], predecessors: [ParentKey: Int] = [:]
        for (index, node) in nodes.enumerated() {
            try check()
            let parent = node.parent.flatMap { assigned[$0] }, id = assigned[index]!
            let group = ParentKey(id: parent, section: node.section)
            entries.append(TreeEntry(id: id, reference: node.reference, description: node.description,
                                     parentID: parent, section: node.section, depth: depths[index], predecessorID: predecessors[group]))
            predecessors[group] = id
        }
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        let newByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        var changes: [TreeChange<Reference>] = []
        for entry in entries {
            if let before = oldByID[entry.id] {
                if before.parentID != entry.parentID || before.section != entry.section || before.predecessorID != entry.predecessorID {
                    changes.append(TreeChange(kind: .moved, before: before, after: entry))
                } else if before.description != entry.description {
                    changes.append(TreeChange(kind: .modified, before: before, after: entry))
                }
            } else { changes.append(TreeChange(kind: .inserted, before: nil, after: entry)) }
        }
        for entry in old where newByID[entry.id] == nil { changes.append(TreeChange(kind: .removed, before: entry, after: nil)) }
        var fullLines: [String] = []
        for section in sections {
            fullLines += [section.opening] + entries.filter { $0.section == section.key }.map(\.line) + ["</app>"]
        }
        if truncated { fullLines.append("Accessibility tree truncated; omitted controls require a new observation.") }
        let fullText = fullLines.joined(separator: "\n")
        var text = fullText, isDiff = false
        if let previous, !forceFull, !truncated, !previous.truncated {
            if changes.isEmpty && previous.sections == sections {
                text = "There has been no change in the accessibility tree for \(ElementDescription.escape(appName))."
                isDiff = true
            } else {
                let changed = Dictionary(uniqueKeysWithValues: changes.compactMap { change in change.after.map { ($0.id, change.kind) } })
                var included = Set(changed.keys)
                for id in changed.keys {
                    var ancestor = newByID[id]?.parentID
                    while let current = ancestor { included.insert(current); ancestor = newByID[current]?.parentID }
                }
                var lines: [String] = []
                for section in sections {
                    let rows = entries.filter { $0.section == section.key && included.contains($0.id) }
                    if !rows.isEmpty || previous.sections != sections {
                        lines.append(section.opening)
                        for entry in rows {
                            let prefix = changed[entry.id].map { $0 == .inserted ? "+" : "~" } ?? " "
                            lines.append(prefix + entry.line)
                        }
                        lines.append("</app>")
                    }
                }
                let removed = changes.filter { $0.kind == .removed }.compactMap { $0.before?.id }.sorted()
                if !removed.isEmpty { lines.append("Removed element IDs: " + removed.map(String.init).joined(separator: ", ")) }
                if lines.count <= maxDiffLines && lines.count < fullLines.count {
                    text = lines.joined(separator: "\n"); isDiff = true
                }
            }
        }
        try check()
        let result = TreeRevision(session: session, number: revisionNumber + 1, sections: sections, entries: entries,
                                  changes: changes, fullText: fullText, text: text, isDiff: isDiff, truncated: truncated)
        current = result; nextID = candidateNext; revisionNumber += 1
        return result
    }
}
