import Foundation

// 0x10023A29C; UIElementProtocol slot 56 and AccessibilityNode slots 48,56,64,80,88,72,216,
// 104,112,120. Subrole and role description participate; actions, enabled,
// position and parent identity do not. Optional strings use Swift equality.
enum EventStreamElementValidation {
    static func matches<Element>(_ lhs: EventStreamTransformedNode<Element>,
                                 _ rhs: EventStreamTransformedNode<Element>, ignoreValueChange: Bool) -> Bool {
        lhs.role == rhs.role && lhs.subrole == rhs.subrole && lhs.roleDescription == rhs.roleDescription &&
        lhs.title == rhs.title && lhs.description == rhs.description &&
        (ignoreValueChange || lhs.value == rhs.value) && lhs.valueDescription == rhs.valueDescription &&
        lhs.placeholderValue == rhs.placeholderValue && lhs.help == rhs.help &&
        lhs.identifier == rhs.identifier && lhs.url == rhs.url
    }
}
