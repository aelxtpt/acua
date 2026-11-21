import CoreFoundation
import Foundation
import os

enum ControllerStringConversionError: Error, Equatable {
    case invalidNumber(String)
    case invalidDate(String)
    case unknownType(CFTypeID?)
}

enum ControllerStringValueConversion {
    enum Kind: UInt8, Sendable { case floating, integer, boolean, string, date, unsupported }
    enum DateFormat: UInt8, Sendable { case date, time, dateAndTime, monthAndYear }
    enum Value {
        case number(NSNumber), boolean(Bool), string(String), date(Date)
        var foundationValue: AnyObject {
            switch self {
            case .number(let value): return value
            case .boolean(let value): return value ? kCFBooleanTrue! : kCFBooleanFalse!
            case .string(let value): return value as NSString
            case .date(let value): return value as NSDate
            }
        }
    }
    struct Environment {
        let calendar: () -> Calendar
        let dateFormatter: (DateFormat) -> DateFormatter
        let logUnknownDateComponents: (UInt) -> Void
        static var native: Self {
            .init(calendar: { .current }, dateFormatter: makeDateFormatter, logUnknownDateComponents: {
                Logger(subsystem: "local.cua", category: "StringValueConversion").error("Unrecognized AXDateTimeComponents: \($0)")
            })
        }
    }

    /// Keep getter ordering: the checkbox subrole may be read twice,
    /// and absent encoded values use a role fallback only for text controls.
    static func kind(encodedValue: () -> AnyObject?, role: () -> String, subrole: () -> String?) -> Kind {
        if let raw = encodedValue() {
            if role() == "AXCheckBox", subrole() == "AXSwitch" || subrole() == "AXToggle" { return .boolean }
            let type = CFGetTypeID(raw)
            if type == CFNumberGetTypeID() {
                return CFNumberIsFloatType(unsafeDowncast(raw, to: CFNumber.self)) ? .floating : .integer
            }
            if type == CFBooleanGetTypeID() { return .boolean }
            if type == CFStringGetTypeID() { return .string }
            if type == CFDateGetTypeID() { return .date }
            return .unsupported
        }
        return role() == "AXTextField" || role() == "AXTextArea" ? .string : .unsupported
    }

    /// The display format uses the full mask. Component replacement below
    /// uses only its low byte.
    static func dateFormat(_ mask: UInt, logUnknown: (UInt) -> Void) -> DateFormat {
        switch mask {
        case 224: return .date
        case 12, 14: return .time
        case 236, 238: return .dateAndTime
        case 192: return .monthAndYear
        default: logUnknown(mask); return .dateAndTime
        }
    }
    static func makeDateFormatter(_ style: DateFormat) -> DateFormatter {
        let formatter = DateFormatter()
        switch style {
        case .date: formatter.dateStyle = .short; formatter.timeStyle = .none
        case .time: formatter.timeStyle = .short; formatter.dateStyle = .none
        case .dateAndTime: formatter.dateStyle = .short; formatter.timeStyle = .short
        case .monthAndYear: formatter.dateFormat = "MMMM yyyy"
        }
        // Deliberately uses the user's default date locale/timezone.
        return formatter
    }
    static func dateComponents(_ mask: UInt) -> Set<Calendar.Component> {
        let bits = UInt8(truncatingIfNeeded: mask)
        var result: Set<Calendar.Component> = []
        for (bit, component) in [(UInt8(2), Calendar.Component.second), (4, .minute), (8, .hour),
                                 (32, .day), (64, .month), (128, .year)] where bits & bit != 0 {
            result.insert(component)
        }
        return result
    }

    /// The numeric cases share NSNumberFormatter decimal/en_US parsing;
    /// an integer-shaped existing value does not force integer-only input.
    static func convert(_ text: String, kind: Kind, encodedValue: () -> AnyObject?,
                        dateTimeComponents: () -> UInt, environment: Environment = .native) throws -> Value {
        switch kind {
        case .floating, .integer:
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US")
            guard let value = formatter.number(from: text) else { throw ControllerStringConversionError.invalidNumber(text) }
            return .number(value)
        case .boolean:
            switch text.lowercased() {
            case "on": return .boolean(true)
            case "off": return .boolean(false)
            default: return .boolean((text as NSString).boolValue)
            }
        case .string: return .string(text)
        case .unsupported: throw ControllerStringConversionError.unknownType(encodedValue().map(CFGetTypeID))
        case .date:
            guard let raw = encodedValue(), CFGetTypeID(raw) == CFDateGetTypeID(), let oldDate = raw as? Date else {
                // This second read is required to be a CFDate.
                preconditionFailure("A date conversion requires a current CFDate value")
            }
            let fields: Set<Calendar.Component> = [.month, .year, .day, .hour, .minute, .second, .timeZone]
            var merged = environment.calendar().dateComponents(fields, from: oldDate)
            let format = dateFormat(dateTimeComponents(), logUnknown: environment.logUnknownDateComponents)
            guard let parsed = environment.dateFormatter(format).date(from: text) else {
                throw ControllerStringConversionError.invalidDate(text)
            }
            let supplied = environment.calendar().dateComponents(fields, from: parsed)
            // Read the mask again after parsing; the
            // formatter choice and components can come from different reads.
            for component in dateComponents(dateTimeComponents()) { merged.setValue(supplied.value(for: component), for: component) }
            guard let value = environment.calendar().date(from: merged) else { throw ControllerStringConversionError.invalidDate(text) }
            return .date(value)
        }
    }
}
