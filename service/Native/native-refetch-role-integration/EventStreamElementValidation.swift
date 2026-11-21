import Foundation
import CoreFoundation

// Two snapshots describe the same element when role, subrole, role
// description and the text fields agree; actions, enabled state, position and
// parent identity do not participate. Role uses CFString equality; optional
// text fields use Swift canonical string equality.
enum EventStreamElementValidation {
    static func matches<Element>(_ lhs: EventStreamTransformedNode<Element>,
                                 _ rhs: EventStreamTransformedNode<Element>, ignoreValueChange: Bool) -> Bool {
        CFEqual(lhs.role as CFString, rhs.role as CFString) && lhs.subrole == rhs.subrole && lhs.roleDescription == rhs.roleDescription &&
        lhs.title == rhs.title && lhs.description == rhs.description &&
        (ignoreValueChange || lhs.value == rhs.value) && lhs.valueDescription == rhs.valueDescription &&
        lhs.placeholderValue == rhs.placeholderValue && lhs.help == rhs.help &&
        lhs.identifier == rhs.identifier && lhs.url == rhs.url
    }
}
