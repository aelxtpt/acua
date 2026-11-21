import Foundation
import Security

/// ACUA's own identity: the bundle identifier namespace it ships under and the
/// signing team read from the running process's own code signature. No other
/// team or bundle namespace is trusted.
enum AcuaOwnIdentity {
    static let bundleIdentifier = "com.aex.computeruse"

    /// `com.aex.computeruse` itself or one of its dotted children, such as
    /// `com.aex.computeruse.client`. Matching is case sensitive.
    static func isOwnBundleIdentifier(_ identifier: String) -> Bool {
        identifier == bundleIdentifier || identifier.hasPrefix(bundleIdentifier + ".")
    }

    /// The team identifier of the current process's code signature, or nil
    /// when the process is unsigned or ad-hoc signed.
    static func signingTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any] else { return nil }
        return information[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

/// A value snapshot; native identity lookup stays outside the request runtime.
struct SenderProcessIdentity: Equatable, Sendable {
    var team: String?
    var signingID: String?
    var bundleID: String?
    var executable: String?

    func matches(identifiers: Set<String>, executables: Set<String>) -> Bool {
        if identifiers.isEmpty && executables.isEmpty { return true }
        return [bundleID, signingID].contains { $0.map(identifiers.contains) == true } ||
            executable.map { executables.contains($0.lowercased()) } == true
    }

    /// True when the bundle or signing identifier is one of ACUA's own. The
    /// executable name is never enough.
    /// Only the bundle ID counts: a signing ID is chosen at signing time and
    /// can name anything, so it never vouches for an ACUA app on its own.
    var hasOwnBundleIdentifier: Bool {
        bundleID.map(AcuaOwnIdentity.isOwnBundleIdentifier) == true
    }
}

/// The client type is either `node_repl` or any other reported string;
/// absence is distinct from both. The runtime is independent of the client type.
struct SenderClientMetadata: Equatable, Sendable {
    enum ClientType: Equatable, Sendable {
        case unknown(String), nodeRepl
        static func parse(_ raw: String?) -> Self? {
            raw.map { $0 == "node_repl" ? .nodeRepl : .unknown($0) }
        }
    }
    enum MCPRuntime: String, Sendable { case legacyMCP = "legacy_mcp", nodeRepl = "node_repl" }
    static let nativeBridgeVersion = "AcuaComputerUseNativeBridge-1"
    var clientType: ClientType?
    var mcpRuntime: MCPRuntime?
    static let socket = Self(clientType: nil, mcpRuntime: .nodeRepl)
    static func appleEvent(clientType: String?, version: String?) -> Self {
        .init(clientType: ClientType.parse(clientType),
              mcpRuntime: version == nativeBridgeVersion ? nil : .legacyMCP)
    }
    var returnsActionAppSnapshot: Bool { clientType != .nodeRepl }
    func acceptsVersion(_ version: String?, ipcVersion: String) -> Bool {
        clientType == .nodeRepl || version == ipcVersion || version == Self.nativeBridgeVersion
    }
}

/// A transport-lifetime snapshot of identity, client/runtime and grant role.
struct SenderRequestContext: Equatable, Sendable {
    let senderPID: Int32
    let responsibleIdentity: SenderProcessIdentity?
    let ancestorIdentities: [SenderProcessIdentity]
    var foregroundOnly: Bool = false
    var clientMetadata = SenderClientMetadata(clientType: nil, mcpRuntime: nil)
    var parentIdentity: SenderProcessIdentity? { ancestorIdentities.first }

    func withAppleEventMetadata(clientType: String?, version: String?) -> Self {
        var copy = self
        copy.clientMetadata = .appleEvent(clientType: clientType, version: version)
        return copy
    }

    /// Lock-screen auto-unlock, judged against the service's own signing team.
    var allowsLockScreenAutoUnlock: Bool {
        allowsLockScreenAutoUnlock(ownTeam: AcuaOwnIdentity.signingTeam())
    }

    /// Auto-unlock is reserved for senders whose responsible process is one of
    /// ACUA's own apps (`com.aex.computeruse` or `com.aex.computeruse.*`)
    /// signed by `ownTeam`. A missing team or identity fails closed.
    func allowsLockScreenAutoUnlock(ownTeam: String?) -> Bool {
        guard let ownTeam, let responsibleIdentity, responsibleIdentity.team == ownTeam else { return false }
        return responsibleIdentity.hasOwnBundleIdentifier
    }

    struct Resolver {
        var ancestorPIDs: (Int32) -> [Int32]
        var identity: (Int32) -> SenderProcessIdentity
        var responsiblePID: (Int32) -> Int32?

        func resolve(_ senderPID: Int32) -> SenderRequestContext? {
            guard senderPID > 0 else { return nil }
            // Resolve every ancestor first, then the responsible identity.
            let ancestors = ancestorPIDs(senderPID).map(identity)
            let responsible = responsiblePID(senderPID).flatMap { $0 > 0 ? identity($0) : nil }
            return SenderRequestContext(senderPID: senderPID, responsibleIdentity: responsible,
                                        ancestorIdentities: ancestors)
        }
    }
}
