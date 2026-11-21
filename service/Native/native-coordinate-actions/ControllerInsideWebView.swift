import Foundation

/// An element is inside a web view when its inclusive parent chain contains an
/// AXWebArea. This element predicate differs from ApplicationUIElement.isWebShaped.
enum ControllerInsideWebView {
    static func test<Node>(_ node: Node, role: (Node) -> String?, parent: @escaping (Node) -> Node?) -> Bool {
        for ancestor in AXParentChain(start: node, parent: parent) {
            if role(ancestor) == "AXWebArea" { return true }
        }
        return false
    }
}
