import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum ControllerMenuWindowID {
    struct NotFound: Error {}
    struct Environment<Node> {
        let actualPID: (Node) throws -> Int32
        let rawWindowID: (Node) throws -> UInt32
        let windows: (UInt32, UInt32) -> [ControllerWindowDescription]
    }
    /// Owner first, raw anchor second, options 18, first owner+level match.
    static func read<Node>(_ node: Node, environment: Environment<Node>) throws -> UInt32 {
        let pid = try environment.actualPID(node)
        let anchor = try environment.rawWindowID(node)
        guard let match = environment.windows(18, anchor).first(where: {
            $0.ownerPID == pid && ($0.level == 101 || $0.level == 24)
        }) else { throw NotFound() }
        return match.id
    }
    static func read(_ element: AXUIElement) throws -> UInt32 {
        try read(element, environment: .init(actualPID: { try ControllerAXProcessID.read($0) },
            rawWindowID: { try ControllerWindowID.read($0) }, windows: windows))
    }
    static func windows(_ options: UInt32, _ relative: UInt32) -> [ControllerWindowDescription] {
        guard let rows = CGWindowListCopyWindowInfo(CGWindowListOption(rawValue: options), relative)
                as? [[AnyHashable: Any]] else { return [] }
        return rows.map { ControllerWindowDescription(info: $0) }
    }
}

enum ControllerAXProcessID {
    enum Failure: Error { case unavailable, accessibility(Int32) }
    typealias Function = @convention(c) (AXUIElement, UnsafeMutablePointer<Int32>) -> Int32
    private static let function: Function? = {
        guard let library = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL),
              let symbol = dlsym(library, "AXUIElementGetActualPid") ?? dlsym(library, "_AXUIElementGetActualPid") else { return nil }
        return unsafeBitCast(symbol, to: Function.self)
    }()
    static var available: Bool { function != nil }
    static func read(operation: (inout Int32) -> Int32?) throws -> Int32 {
        // The raw fallback output starts at -1, not zero.
        var result: Int32 = -1
        guard let status = operation(&result) else { throw Failure.unavailable }
        guard status == 0 else { throw Failure.accessibility(status) }
        return result
    }
    static func read(_ element: AXUIElement) throws -> Int32 {
        try read { value in
            guard let function else { return nil }
            return function(element, &value)
        }
    }
}
