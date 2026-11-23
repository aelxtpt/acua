import Foundation

enum AcuaApprovalFormError: Error, Equatable, CustomStringConvertible {
    case missingMessage
    case schemaNotAnObject
    case unsupportedField(String)

    var description: String {
        switch self {
        case .missingMessage: "The approval form has no message."
        case .schemaNotAnObject: "The approval form's requestedSchema is not an object schema."
        case .unsupportedField(let key): "The approval form field '\(key)' is not a kind the service dialog can show."
        }
    }
}

/// `ComputerUseIPCApprovalFormRequest`: an elicitation form the MCP helper
/// could not send, because its client did not declare elicitation, drawn by
/// the service instead. Only the schema kinds the helper's own forms use are
/// accepted; anything else is refused rather than drawn wrong.
struct AcuaApprovalForm: Equatable {
    struct Option: Equatable {
        let value: String
        let title: String
    }

    enum Field: Equatable {
        case text(key: String, title: String?, detail: String?, value: String)
        case multipleChoice(key: String, title: String?, options: [Option], selected: [String])
        case choice(key: String, title: String?, options: [Option], selected: String?)
        case toggle(key: String, title: String?, isOn: Bool)

        var key: String {
            switch self {
            case .text(let key, _, _, _), .multipleChoice(let key, _, _, _), .choice(let key, _, _, _), .toggle(let key, _, _):
                return key
            }
        }

        /// Fields are drawn in a fixed order, since JSON objects have none:
        /// what is edited or picked first, the options that qualify it after.
        fileprivate var drawingRank: Int {
            switch self {
            case .text: 0
            case .multipleChoice: 1
            case .choice: 2
            case .toggle: 3
            }
        }
    }

    /// A value the user set in the dialog.
    enum Value {
        case text(String)
        case choices([String])
        case choice(String)
        case toggle(Bool)
    }

    enum Action: String {
        case accept
        case decline
        case cancel
    }

    let message: String
    let detail: String?
    let fields: [Field]

    /// `body` is the request: {"message", "detail"?, "requestedSchema"}.
    init(_ body: [String: Any]) throws {
        guard let message = body["message"] as? String, !message.isEmpty else {
            throw AcuaApprovalFormError.missingMessage
        }

        let schema = body["requestedSchema"] as? [String: Any]
        guard let schema, schema["type"] as? String == "object" else {
            throw AcuaApprovalFormError.schemaNotAnObject
        }

        let properties = schema["properties"] as? [String: Any] ?? [:]
        let fields = try properties.map { key, property in
            guard let property = property as? [String: Any] else {
                throw AcuaApprovalFormError.unsupportedField(key)
            }
            return try Self.field(key, property)
        }

        self.message = message
        self.detail = body["detail"] as? String
        self.fields = fields.sorted { ($0.drawingRank, $0.key) < ($1.drawingRank, $1.key) }
    }

    /// The elicitation result the helper decodes: {"action", "content"?}.
    /// Every field is sent, at its default when the user left it alone; the
    /// helper validates the values as it does an elicitation answer.
    func answer(_ action: Action, values: [String: Value]) -> [String: Any] {
        guard action == .accept else {
            return ["action": action.rawValue]
        }

        var content: [String: Any] = [:]
        for field in fields {
            content[field.key] = Self.json(values[field.key] ?? Self.defaultValue(field))
        }

        return ["action": action.rawValue, "content": content]
    }

    private static func defaultValue(_ field: Field) -> Value {
        switch field {
        case .text(_, _, _, let value): return .text(value)
        case .multipleChoice(_, _, _, let selected): return .choices(selected)
        case .choice(_, _, let options, let selected): return .choice(selected ?? options.first?.value ?? "")
        case .toggle(_, _, let isOn): return .toggle(isOn)
        }
    }

    private static func json(_ value: Value) -> Any {
        switch value {
        case .text(let text): return text
        case .choices(let values): return values
        case .choice(let value): return value
        case .toggle(let isOn): return isOn
        }
    }

    private static func field(_ key: String, _ property: [String: Any]) throws -> Field {
        let title = property["title"] as? String

        switch property["type"] as? String {
        case "string":
            if let options = options(property) {
                return .choice(key: key, title: title, options: options, selected: property["default"] as? String)
            }
            return .text(key: key, title: title, detail: property["description"] as? String,
                         value: property["default"] as? String ?? "")
        case "boolean":
            return .toggle(key: key, title: title, isOn: property["default"] as? Bool ?? false)
        case "array":
            guard let items = property["items"] as? [String: Any], let options = options(items) else {
                throw AcuaApprovalFormError.unsupportedField(key)
            }
            return .multipleChoice(key: key, title: title, options: options, selected: property["default"] as? [String] ?? [])
        default:
            throw AcuaApprovalFormError.unsupportedField(key)
        }
    }

    /// `oneOf`/`anyOf` of {"const", "title"}, or a plain `enum` of strings.
    private static func options(_ schema: [String: Any]) -> [Option]? {
        if let values = schema["enum"] as? [String] {
            return values.map { Option(value: $0, title: $0) }
        }

        guard let alternatives = (schema["oneOf"] ?? schema["anyOf"]) as? [[String: Any]] else {
            return nil
        }

        let options = alternatives.compactMap { alternative -> Option? in
            guard let value = alternative["const"] as? String else { return nil }
            return Option(value: value, title: alternative["title"] as? String ?? value)
        }
        return options.count == alternatives.count ? options : nil
    }
}
