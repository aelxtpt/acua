import ApplicationServices
import Foundation

struct ControllerPasteRawValue: @unchecked Sendable { let raw: AnyObject }
typealias ControllerPasteValues = [String:ControllerPasteRawValue]

enum ControllerNativePasteValueChanges {
    private static func noValue(_ value: ControllerPasteRawValue?) -> Bool {
        guard let value, CFGetTypeID(value.raw) == AXValueGetTypeID() else { return false }
        let raw = unsafeDowncast(value.raw,to:AXValue.self)
        guard AXValueGetType(raw) == .axError else { return false }
        var error = AXError.success
        return AXValueGetValue(raw,.axError,&error) && error == .noValue
    }
    private static func string(_ value: ControllerPasteRawValue?) -> AnyObject? {
        guard let value, CFGetTypeID(value.raw) == CFStringGetTypeID() else { return nil }; return value.raw
    }
    private static func count(_ value: ControllerPasteRawValue?) -> Int? {
        guard let value, CFGetTypeID(value.raw) == CFNumberGetTypeID(), let number = value.raw as? NSNumber else { return nil }
        let integer = number.intValue
        guard integer >= 0, number.doubleValue == Double(integer) else { return nil }; return integer
    }
    private static func range(_ value: ControllerPasteRawValue?) -> AnyObject? {
        guard let value, CFGetTypeID(value.raw) == AXValueGetTypeID(),
              AXValueGetType(unsafeDowncast(value.raw,to:AXValue.self)) == .cfRange else { return nil }; return value.raw
    }
    /// Compares only these three attributes, with CF equality rather
    /// than Swift's canonically equivalent String comparison.
    static func changed(from old: ControllerPasteValues, to fresh: ControllerPasteValues) -> Bool {
        if let new = string(fresh["AXValue"]) {
            if let previous = string(old["AXValue"]) { if !CFEqual(previous,new) { return true } }
            else if noValue(old["AXValue"]), unsafeDowncast(new,to:NSString.self).length > 0 { return true }
        }
        if let new = count(fresh["AXNumberOfCharacters"]) {
            if let previous = count(old["AXNumberOfCharacters"]) { if previous != new { return true } }
            else if noValue(old["AXNumberOfCharacters"]), new != 0 { return true }
        }
        if let previous = range(old["AXSelectedTextRange"]), let new = range(fresh["AXSelectedTextRange"]) {
            return !CFEqual(previous,new)
        }
        return false
    }
}
