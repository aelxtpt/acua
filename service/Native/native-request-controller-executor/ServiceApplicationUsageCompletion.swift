/// Encode the native response, then re-resolve and notify app use.
/// The outer socket response conversion happens later. No native body crosses
/// an actor here, and failures keep their ordering and identity.
enum ServiceApplicationUsageCompletion {
    static func encode<Response, Encoded>(typeName: String, identifier: String,
        response: Response, encode: (Response) throws -> Encoded,
        resolveIdentifier: (String) throws -> String, appUsed: ((String) -> Void)?) throws -> Encoded {
        let encoded = try encode(response)
        if RequestPreparation(requestType: typeName).isAppUsage, let appUsed {
            appUsed(try resolveIdentifier(identifier))
        }
        return encoded
    }
}
