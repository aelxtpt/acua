import Foundation

enum ControllerHeldClickKeyFailure: Error, Equatable {
    case unknownSymbol(String)
    case unsupportedSymbols([String])
    case multiplePhysicalKeys
    case requiresSingleNonemptyStroke
}
struct ControllerHeldClickKey: Sendable, Equatable {
    let keyCode: UInt16?
    let carbonModifiers: UInt32
    let eventFlags: UInt64
    static let none = Self(keyCode: nil, carbonModifiers: 0, eventFlags: 0)
    /// Split on literal ASCII spaces, then plus signs, omitting empty
    /// pieces. Symbol matching is case-sensitive and precedes stroke validation.
    static func parse(_ input: String) throws -> Self {
        let strokes = try input.split(separator: " ", omittingEmptySubsequences: true).map { stroke in
            try stroke.split(separator: "+", omittingEmptySubsequences: true).map { token in
                guard let entry = ControllerKeysymTable.byName[String(token)] else { throw ControllerHeldClickKeyFailure.unknownSymbol(String(token)) }
                return entry
            }
        }
        guard strokes.count == 1, let stroke = strokes.first, !stroke.isEmpty else { throw ControllerHeldClickKeyFailure.requiresSingleNonemptyStroke }
        var code: UInt16?, carbon: UInt32 = 0, flags: UInt64 = 0
        for entry in stroke {
            guard let key = entry.keyCode else { throw ControllerHeldClickKeyFailure.unsupportedSymbols(stroke.map(\.name)) }
            if !entry.isModifier {
                guard code == nil else { throw ControllerHeldClickKeyFailure.multiplePhysicalKeys }
                code = key
            }
            carbon |= entry.carbonModifiers; flags |= entry.eventFlags
        }
        return .init(keyCode: code, carbonModifiers: carbon, eventFlags: flags)
    }
}
