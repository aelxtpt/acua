import Foundation

enum ControllerKeyboardStrokeParsingFailure: Error, Equatable {
    case unknownSymbol(String)
    case unsupportedSymbols([String])
    case physicalKeyMustBeLast([String])
    case missingPhysicalKey([String])
}
enum ControllerKeyboardStrokeParsing {
    /// First resolves *all* tokens, then converts each
    /// stroke. A later unknown token therefore precedes an earlier shape error.
    static func parse(_ input: String) throws -> [ControllerKeyboardStroke] {
        let strokes = try input.split(separator: " ", omittingEmptySubsequences: true).map { stroke in
            try stroke.split(separator: "+", omittingEmptySubsequences: true).map { token in
                guard let entry = ControllerKeysymTable.byName[String(token)] else {
                    throw ControllerKeyboardStrokeParsingFailure.unknownSymbol(String(token))
                }
                return entry
            }
        }
        return try strokes.map { entries in
            let symbols = entries.map(\.name)
            var code: UInt16?
            var flags: UInt64 = 0
            for entry in entries {
                guard let native = entry.keyCode else { throw ControllerKeyboardStrokeParsingFailure.unsupportedSymbols(symbols) }
                guard code == nil else { throw ControllerKeyboardStrokeParsingFailure.physicalKeyMustBeLast(symbols) }
                flags |= entry.eventFlags
                if !entry.isModifier { code = native }
            }
            guard let code else { throw ControllerKeyboardStrokeParsingFailure.missingPhysicalKey(symbols) }
            return .init(keyCode: code, flags: flags, unicode: nil)
        }
    }
}
