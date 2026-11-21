import Foundation

enum ScrollToVisiblePlan {
    enum Step<Node> { case action(Node), attribute(Node), scrollArea(Node) }
    enum Failure: Error { case cyclicAncestry }

    // Collect leaf-to-root operations before executing
    // any of them. A covering action suppresses ancestor operations until a
    // scroll-area/group clipping boundary resets the coverage.
    static func collect<Node, Identity: Hashable>(from root: Node,
        identity: (Node) -> Identity, role: (Node) throws -> String,
        actions: (Node) throws -> [String], settable: (Node) throws -> Bool,
        parent: (Node) throws -> Node?, checkpoint: () throws -> Void
    ) throws -> [Step<Node>] {
        var node: Node? = root
        var covered = false
        var seen = Set<Identity>()
        var result = [Step<Node>]()
        while let current = node {
            try checkpoint()
            guard seen.insert(identity(current)).inserted else { throw Failure.cyclicAncestry }
            let kind = try role(current)
            if ClickableGeometry.boundary(role: kind) { break }
            let supported = !covered || kind == "AXGroup" ? try actions(current) : []
            var covering = covered
            if !covered {
                if supported.contains("AXScrollToVisible") {
                    result.append(.action(current)); covering = true
                } else if kind == "AXCell", try settable(current) {
                    result.append(.attribute(current)); covering = true
                }
            }
            if !covering && kind == "AXScrollArea" { result.append(.scrollArea(current)) }
            covered = covering && !ClickableGeometry.clips(role: kind, actions: supported)
            node = try parent(current)
        }
        return result
    }
}
