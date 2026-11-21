import Foundation

enum NativeScrollActionDirection: UInt8 {
    case up, down, left, right
    init?(action: String) {
        switch action {
        case "AXScrollUpByPage": self = .up
        case "AXScrollDownByPage": self = .down
        case "AXScrollLeftByPage": self = .left
        case "AXScrollRightByPage": self = .right
        default: return nil
        }
    }
    var vertical: Bool { self == .up || self == .down }
    var pageButtonSubrole: String {
        self == .up || self == .left ? "AXDecrementPage" : "AXIncrementPage"
    }
}

protocol NativeElementActionBackend {
    associatedtype Element
    associatedtype Identity: Hashable
    func identity(_ element: Element) -> Identity
    func role(_ element: Element) throws -> String?
    func subrole(_ element: Element) throws -> String?
    func parent(_ element: Element) throws -> Element?
    func children(_ element: Element) throws -> [Element]
    func childrenPreferringVisible(_ element: Element) throws -> [Element]
    func actions(_ element: Element) throws -> [String]
    func canDisclose(_ element: Element) throws -> Bool
    func isDisclosing(_ element: Element) throws -> Bool
    func setDisclosing(_ value: Bool, for element: Element) throws
    func scrollBar(_ element: Element, vertical: Bool) throws -> Element?
    func performAX(_ action: String, on element: Element) throws
    func checkpoint() throws
}

enum NativeElementAction {
    enum Failure: Error { case cyclicActionDependency }

    // UIElementProtocol.perform(action:). A menu ancestor
    // may need the action first; successful forwarding still acts on self.
    static func perform<B: NativeElementActionBackend>(_ element: B.Element, action: String,
                                                       backend: B) throws {
        try perform(element, action: action, backend: backend, path: [])
    }

    private static func perform<B: NativeElementActionBackend>(_ element: B.Element, action: String,
        backend: B, path: Set<B.Identity>) throws {
        try backend.checkpoint()
        let id = backend.identity(element)
        guard !path.contains(id) else { throw Failure.cyclicActionDependency }
        var path = path; path.insert(id)
        if try backend.role(element) == "AXMenuItem" {
            var candidates = [B.Element]()
            var next = try backend.parent(element)
            for _ in 1...300 {
                try backend.checkpoint()
                guard let current = next else { break }
                // The parent iterator prefetches before yielding.
                next = try backend.parent(current)
                if try !backend.childrenPreferringVisible(current).isEmpty { break }
                candidates.append(current)
            }
            for candidate in candidates {
                try backend.checkpoint()
                if try backend.actions(candidate).contains(action) {
                    try perform(candidate, action: action, backend: backend, path: path)
                    break
                }
            }
        }
        try backend.checkpoint()
        if action == "SAIExpand" || action == "SAICollapse" {
            // Both synthetic action names toggle, rather than force a state.
            if try backend.canDisclose(element) {
                let value = try !backend.isDisclosing(element)
                try backend.checkpoint()
                try backend.setDisclosing(value, for: element)
            }
            return
        }
        if let direction = NativeScrollActionDirection(action: action),
           let bar = try backend.scrollBar(element, vertical: direction.vertical) {
            for child in try backend.children(bar) {
                try backend.checkpoint()
                if try backend.role(child) == "AXButton",
                   try backend.subrole(child) == direction.pageButtonSubrole {
                    try perform(child, action: "AXPress", backend: backend, path: path)
                    return
                }
            }
        }
        try backend.checkpoint()
        try backend.performAX(action, on: element)
    }
}
