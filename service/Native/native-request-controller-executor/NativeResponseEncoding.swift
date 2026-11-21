import Foundation

/// The native response is Encodable; the legacy adapter currently
/// returns Any. Validate that boundary before Foundation can raise an ObjC
/// exception for unsupported or nonfinite values. Valid output is unchanged.
enum NativeResponseEncoding {
    static func encode(_ value: Any) throws -> Data {
        // Validate containers directly so their supported nesting depth does
        // not shrink. Wrap only fragments, which the validator otherwise rejects.
        let valid = value is NSArray || value is NSDictionary
            ? JSONSerialization.isValidJSONObject(value)
            : JSONSerialization.isValidJSONObject([value])
        guard valid else {
            throw EncodingError.invalidValue(value, .init(codingPath: [],
                debugDescription: "The native response contains a value that cannot be encoded as JSON."))
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
    }
}
