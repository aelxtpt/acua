import Foundation

/// Policy decisions run before request activity and preparation.
/// The body stays on the connection worker; no unchecked transfer of JSON is needed.
enum ServiceRequestPreflight<Body> {
    case policy(Body)
    case ordinary(Body?)

    static func run(contract: ServiceRequestContract, decode: () throws -> Body,
        modificationActivates: (Body) -> Bool,
        applicationPolicy: (Body) throws -> Void,
        configurationPolicy: () throws -> Void) throws -> Self {
        let early = contract.decodesBeforePolicy ? try decode() : nil
        if contract.preparation.isPolicy { return .policy(early!) }
        if contract.preparation.isAppUsage || contract.isModify && modificationActivates(early!) {
            try applicationPolicy(early!)
        }
        if contract.checksGlobalConfiguration { try configurationPolicy() }
        return .ordinary(early)
    }
}
