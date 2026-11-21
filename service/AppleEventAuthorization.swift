import Foundation

/// Signature-based Apple Event admission. The sender must be signed by the
/// service's own team (`Providers.ownTeam`), checked by audit token or PID,
/// before its context is considered. A sender whose context is not trusted
/// but whose process is signed by the own team gets a restricted,
/// subscription-only grant.
struct AppleEventAuthorization {
    static let nativeBridgeVersion = SenderClientMetadata.nativeBridgeVersion
    enum Failure: Error, Equatable { case missingSenderPID, teamNotFound, notAuthenticated }
    struct Sender {
        let pid: Int32?
        let auditData: Data?
        let version: String?
        var clientType: String? = nil
    }
    struct Providers {
        var ownTeam: () -> String?
        var auditMatches: (Data, String) -> Bool
        var processMatches: (Int32, String) -> Bool
        var isDesignatedHost: (Int32) -> Bool
        var resolveContext: (Int32) -> SenderRequestContext?
        var contextAllowed: (SenderRequestContext) -> Bool
    }
    let providers: Providers

    func authorize(_ sender: Sender) throws -> SenderRequestContext {
        guard let pid = sender.pid else { throw Failure.missingSenderPID }
        // Without the service's own team there is nothing to trust.
        guard let ownTeam = providers.ownTeam() else { throw Failure.teamNotFound }
        func processAllowed() -> Bool { providers.processMatches(pid, ownTeam) }
        let auditAllowed = sender.auditData.map { providers.auditMatches($0, ownTeam) } ?? false
        let signatureAllowed = auditAllowed || processAllowed()
        // A designated host speaking the native bridge protocol is trusted
        // without its ancestry, but only when its own PID is signed by the
        // own team; an audit-token match alone is not enough.
        let designatedBridge = sender.version == Self.nativeBridgeVersion && providers.isDesignatedHost(pid) && processAllowed()
        guard signatureAllowed else { throw Failure.notAuthenticated }
        var context = (providers.resolveContext(pid) ?? .init(senderPID: pid, responsibleIdentity: nil, ancestorIdentities: []))
            .withAppleEventMetadata(clientType: sender.clientType, version: sender.version)
        guard context.senderPID == pid else { throw Failure.notAuthenticated }
        if designatedBridge || providers.contextAllowed(context) {
            context.foregroundOnly = false
            return context
        }
        if processAllowed() {
            context.foregroundOnly = true
            return context
        }
        throw Failure.notAuthenticated
    }
}
