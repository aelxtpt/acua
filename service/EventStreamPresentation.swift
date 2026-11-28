import Foundation

// Native UIElementRole.presentationKind, with a fixed enum case order.
struct EventStreamPresentationRole {
    enum Kind: UInt8 { case button, checkBox, menu, menuBar, menuBarItem, menuButton, menuItem, radioGroup, row, generic, other }
    let nativeRole: String
    let roleDescription: String?
    var kind: Kind {
        switch nativeRole {
        case "AXButton": return .button
        case "AXCheckBox": return .checkBox
        case "AXMenu": return .menu
        case "AXMenuBar": return .menuBar
        case "AXMenuBarItem": return .menuBarItem
        case "AXMenuButton": return .menuButton
        case "AXMenuItem": return .menuItem
        case "AXRadioGroup": return .radioGroup
        case "AXRow": return .row
        case "AXGenericElement": return .generic
        default: return .other
        }
    }
    // UIElementContextType: 0 fullUIContext, 1 eventStreamContext,
    // 2 informationalContext.
    func description(contextKind: UInt8) -> String {
        if let roleDescription {
            switch kind {
            case .menuBarItem, .menuItem, .radioGroup: return ""
            case .row: return "row"
            case .generic: return roleDescription.isEmpty ? "element" : roleDescription
            case .other: return nativeRole == "AXGroup" ? "container" : roleDescription
            default: return roleDescription
            }
        }
        switch kind {
        case .menu: return "menu"
        case .menuBar: return "menu bar"
        case .menuBarItem, .menuItem, .radioGroup: return ""
        default: return contextKind == 2 ? "" : "unknown"
        }
    }
    func includesAttributes(contextKind: UInt8, hasDescriptiveAttributes: Bool) -> Bool {
        guard contextKind == 2 else { return true }
        switch kind {
        case .button, .checkBox, .menuButton: return hasDescriptiveAttributes
        case .menu, .menuBar: return false
        default: return true
        }
    }
}

struct EventStreamPresentationState {
    var isSelectable = false
    var isSelected = false
    var isEnabled = true
    var isDisclosable = false
    var isDisclosing = false
    var valueTypeDescription: String?
    var isValueSettable = false
    var isSentByMe = false
    var isOffscreen = false

    // Group and static text do not advertise disabled state.
    func description(role: EventStreamPresentationRole, contextKind: UInt8) -> String {
        var values: [String] = []
        if isSelectable && !isSelected && contextKind == 0 { values.append("selectable") }
        if isSelected { values.append("selected") }
        if !isEnabled && contextKind != 2 && role.nativeRole != "AXGroup" && role.nativeRole != "AXStaticText" { values.append("disabled") }
        if isDisclosable { values.append(isDisclosing ? "expanded" : "collapsed") }
        if let valueTypeDescription, isValueSettable {
            values.append(valueTypeDescription == "string" ? "settable" : "settable, " + valueTypeDescription)
        }
        if isSentByMe { values.append("sent by me") }
        if isOffscreen { values.append("offscreen") }
        return values.isEmpty ? "" : "(" + values.joined(separator: ", ") + ")"
    }
}

// Presentation of an already transformed node. Native role,
// value, URL-shortening and transformation providers must supply these values;
// automation's ElementDescription is a different wire representation.
struct EventStreamPresentation {
    struct Action {
        let kind: UInt8
        let description: String
    }

    var title: String?
    var description: String?
    var rows: ClosedRange<Int>?
    var columns: ClosedRange<Int>?
    var trimmedURL: String?
    var help: String?
    var value: String?
    var details: String?
    var placeholder: String?
    var identifier: String?
    var actions: [Action] = []

    private struct Attribute {
        let name: String?
        let value: String
        // Uses Character indices, not UTF-8/UTF-16 length.
        var isLong: Bool {
            value.index(value.startIndex, offsetBy: 101, limitedBy: value.endIndex) != nil || value.contains("\n")
        }
        var rendered: String { name.map { "\($0): \(value)" } ?? value }
    }

    var attributesDescription: String {
        var attributes: [Attribute] = [], seen = Set<String>()
        func append(_ name: String?, _ value: String?) {
            guard let value, !value.isEmpty, seen.insert(value).inserted else { return }
            attributes.append(.init(name: name, value: value))
        }
        func appendRange(_ name: String, _ range: ClosedRange<Int>?) {
            guard let range, range.lowerBound >= 0, range.lowerBound < range.upperBound else { return }
            // Appends directly, bypassing the value-dedup set.
            attributes.append(.init(name: name, value: "\(range.lowerBound)-\(range.upperBound)"))
        }
        append(nil, title)
        append("Description", description)
        appendRange("Rows", rows)
        appendRange("Columns", columns)
        append("URL", trimmedURL)
        append("Help", help)
        append("Value", value)
        append("Details", details)
        append("Placeholder", placeholder)
        if let identifier, !identifier.hasPrefix("_"), !identifier.hasPrefix("NS") { append("ID", identifier) }
        let excludedNames: Set<String> = ["Add comment", "Remove unused rows", "Remove unused columns", "Remove unused rows and columns"]
        let secondary = actions.filter { $0.kind > 2 && !excludedNames.contains($0.description) }.map(\.description)
        if !secondary.isEmpty { append("Secondary Actions", secondary.joined(separator: ", ")) }
        guard !attributes.isEmpty else { return "" }
        // A sole ordinary attribute loses its label; the actions label survives.
        if attributes.count == 1, attributes[0].name != "Secondary Actions" { return attributes[0].value }
        // Stably move long/multiline values after short values.
        return (attributes.filter { !$0.isLong } + attributes.filter(\.isLong)).map(\.rendered).joined(separator: ", ")
    }

    func accessibilityDescription(role: String, state: String) -> String {
        // Combine role, state and attributes in that order.
        [role, state, attributesDescription].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func accessibilityDescription(role: EventStreamPresentationRole, state: EventStreamPresentationState,
                                  contextKind: UInt8, hasDescriptiveAttributes: Bool) -> String {
        [role.description(contextKind: contextKind), state.description(role: role, contextKind: contextKind),
         role.includesAttributes(contextKind: contextKind, hasDescriptiveAttributes: hasDescriptiveAttributes) ? attributesDescription : ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
