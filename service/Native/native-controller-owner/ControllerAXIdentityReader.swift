import ApplicationServices
import Foundation

/// A bridged node supplies both identity fields. Only an absent
/// node falls through to SPI; cached zero/negative values remain authoritative.
struct ControllerAXIdentityReader<Node: Sendable>: Sendable {
    struct Identity: Sendable { let actualPID: Int32; let windowID: UInt32 }
    let lookup: @Sendable (Node) -> Identity?
    let rawWindowID: @Sendable (Node) throws -> UInt32
    let rawActualPID: @Sendable (Node) throws -> Int32

    func windowID(_ node: Node) throws -> UInt32 {
        if let identity = lookup(node) { return identity.windowID }
        return try rawWindowID(node)
    }
    func actualPID(_ node: Node) throws -> Int32 {
        if let identity = lookup(node) { return identity.actualPID }
        return try rawActualPID(node)
    }
}

extension ControllerAXIdentityReader where Node == SettingsNativeAXElement {
    /// A supplied lookup is the current cached-node provider. Its complete native
    /// snapshot owner is still required by the service/capture composition.
    static func native(lookup: @escaping @Sendable (SettingsNativeAXElement) -> Identity?) -> Self {
        .init(lookup: lookup, rawWindowID: { try ControllerWindowID.read($0.element) },
            rawActualPID: { try ControllerAXProcessID.read($0.element) })
    }
}
