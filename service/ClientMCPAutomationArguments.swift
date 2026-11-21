import Foundation
import MCP

enum MCPToolError: Error, CustomStringConvertible {
    case missingArgument(String), invalidArgument(String), unknownTool(String)
    case appBlockedByPolicy(bundleIdentifier: String)
    case appNotAllowed(bundleIdentifier: String)
    case appApprovalDenied(bundleIdentifier: String)
    case appApprovalCanceled(bundleIdentifier: String)
    case appApprovalPersistenceUnavailable(bundleIdentifier: String)

    var description: String {
        switch self {
        case .missingArgument(let key): "Missing required argument: " + key
        case .invalidArgument(let detail): detail
        case .unknownTool(let tool): "Unknown tool: " + tool
        case .appBlockedByPolicy(let app): "Computer Use is blocked from using the app '\(app)' by your organization's policy."
        case .appNotAllowed(let app): "Computer Use is not allowed to use the app '\(app)' for safety reasons."
        case .appApprovalDenied(let app): "Computer Use approval denied via MCP elicitation for app '\(app)'."
        case .appApprovalCanceled(let app): "Computer Use permission request canceled for app '\(app)'."
        case .appApprovalPersistenceUnavailable(let app): "Computer Use could not persist the approval permanently for app '\(app)'."
        }
    }
}

enum AutomationMCPTool: String, CaseIterable, Sendable {
    case listApps = "list_apps", getAppState = "get_app_state", click
    case performSecondaryAction = "perform_secondary_action", setValue = "set_value"
    case selectText = "select_text", scroll, drag, pressKey = "press_key", typeText = "type_text"
}

/// The caller must complete app policy and approval after preflightApp and
/// before calling operation. Action validation is deliberately delayed until then.
struct AutomationMCPArguments {
    enum Operation {
        case listApps
        case getAppState(app: String)
        case performAction(ComputerUseIPCAppPerformActionRequest)
    }

    let values: [String: Value]
    init(_ values: [String: Value]?) { self.values = values ?? [:] }

    func preflightApp(for tool: AutomationMCPTool) throws -> String? {
        tool == .listApps ? nil : try requiredString("app")
    }

    func optionalString(_ key: String) -> String? {
        guard case .string(let value) = values[key] else { return nil }
        return value
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = optionalString(key), !value.isEmpty else {
            throw MCPToolError.missingArgument(key)
        }
        return value
    }

    func requiredNumber(_ key: String) throws -> Double {
        switch values[key] {
        case .int(let number): return Double(number)
        case .double(let number): return number
        default: throw MCPToolError.missingArgument(key)
        }
    }

    func number(_ key: String, default fallback: Double) -> Double {
        switch values[key] {
        case .int(let number): return Double(number)
        case .double(let number): return number
        default: return fallback
        }
    }

    static func mouseButton(_ value: String) throws -> UInt32 {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "left", "l": return 0
        case "right", "r": return 1
        case "middle", "m": return 2
        default: throw MCPToolError.invalidArgument("Invalid mouse button: " + value)
        }
    }

    static func direction(_ value: String) throws -> ComputerUseIPCScrollDirection {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "up", "u": return .up
        case "down", "d": return .down
        case "left", "l": return .left
        case "right", "r": return .right
        default: throw MCPToolError.invalidArgument("Invalid scroll direction: " + value)
        }
    }

    static func selection(_ value: String) throws -> ComputerUseIPCTextSelection {
        guard let selection = ComputerUseIPCTextSelection(rawValue: value) else {
            throw MCPToolError.invalidArgument("Invalid text selection mode: " + value)
        }
        return selection
    }

    func operation(for tool: AutomationMCPTool) throws -> Operation {
        if tool == .listApps { return .listApps }
        let app = try requiredString("app")
        if tool == .getAppState { return .getAppState(app: app) }
        let action: ComputerUseIPCAction
        switch tool {
        case .click:
            let button = try Self.mouseButton(optionalString("mouse_button") ?? "left")
            let count: Int
            if case .int(let value) = values["click_count"] { count = value } else { count = 1 }
            let target: ComputerUseIPCTarget
            if let element = optionalString("element_index") ?? optionalString("element") {
                target = .elementID(element)
            } else {
                let x = try requiredNumber("x")
                target = .coordinate(.init(x: x, y: try requiredNumber("y")))
            }
            action = .click(at: target, mouseButton: button, clickCount: count, duration: nil, key: nil)
        case .performSecondaryAction:
            let element = try requiredString("element_index")
            action = .performSecondaryAction(elementID: element, action: try requiredString("action"))
        case .setValue:
            let element = try requiredString("element_index")
            action = .setValue(elementID: element, value: try requiredString("value"))
        case .selectText:
            let element = try requiredString("element_index")
            let text = try requiredString("text")
            action = .selectText(elementID: element, text: text, prefix: optionalString("prefix"),
                suffix: optionalString("suffix"), selection: try Self.selection(optionalString("selection") ?? "text"))
        case .scroll:
            let direction = try Self.direction(requiredString("direction"))
            let pages = number("pages", default: 1)
            guard !(pages <= 0) else { throw MCPToolError.invalidArgument("pages must be > 0") }
            action = .scroll(at: .elementID(try requiredString("element_index")), direction: direction, pages: pages)
        case .drag:
            let fromX = try requiredNumber("from_x"), fromY = try requiredNumber("from_y")
            let toX = try requiredNumber("to_x"), toY = try requiredNumber("to_y")
            action = .drag(from: .init(x: fromX, y: fromY), to: .init(x: toX, y: toY))
        case .pressKey: action = .pressKey(try requiredString("key"), duration: nil)
        case .typeText: action = .type(try requiredString("text"))
        case .listApps, .getAppState: preconditionFailure("Non-action tools returned above")
        }
        return .performAction(.init(app: app, action: action))
    }
}
