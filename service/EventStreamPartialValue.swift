import Foundation
import ApplicationServices

enum EventStreamAttributeAvailability {
    // Requested attributes describe the completeness of a prefetch table.
    // They are not the element's advertised supported attributes.
    static func mayRead(_ attribute:String,supported:Set<String>,requested:Set<String>?) -> Bool {
        if let requested {if !requested.contains(attribute) {return true}}
        else if supported.isEmpty {return true}
        return supported.contains(attribute)
    }
    static func supports(_ attribute:String,supported:Set<String>,requested:Set<String>?,
                         refresh:()->Set<String>) -> Bool {
        if let requested,!requested.contains(attribute) {return refresh().contains(attribute)}
        return supported.contains(attribute)
    }
}

// AXPartialValue payload. Array coverage and string
// coverage are independent; a string's indices/counts use UTF-16, not Character.
struct EventStreamPartialValue {
    struct ArrayCoverage: Equatable {
        let count: Int
        let availableRanges: [Range<Int>]?
    }
    struct StringCoverage: Equatable {
        let count: Int
        let availableRange: Range<Int>
    }
    let value: AnyObject
    let array: ArrayCoverage?
    let string: StringCoverage?

    static func decode(attribute: String, record: [String:Any],
                       siblings: [String:[String:Any]], arrayAttributes: Set<String>,
                       valueKey: String, countKey: String) -> Self {
        let value = (record[valueKey] as AnyObject?) ?? NSNull()
        var array: ArrayCoverage?
        if CFGetTypeID(value) == CFArrayGetTypeID(), let values = value as? [AnyObject] {
            if arrayAttributes.contains(attribute), let total = record[countKey] as? Int, values.count < total {
                array = .init(count:total,availableRanges:[0..<values.count])
            } else { array = .init(count:values.count,availableRanges:nil) }
        }
        var string: StringCoverage?
        if attribute == "AXValue", CFGetTypeID(value) == CFStringGetTypeID(),
           let text = value as? String, let total = siblings["AXNumberOfCharacters"]?[valueKey] as? Int {
            string = .init(count:total,availableRange:0..<text.utf16.count)
        }
        return .init(value:value,array:array,string:string)
    }
}
