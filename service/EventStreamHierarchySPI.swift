import ApplicationServices
import Darwin
import Foundation

enum EventStreamHierarchySPI {
    private typealias CopyHierarchy = @convention(c) (AXUIElement, CFArray, CFDictionary?,
        UnsafeMutablePointer<Unmanaged<CFDictionary>?>?) -> AXError
    struct Keys {
        let skipInspection, arrayAttributes, truncateStrings, maximumArrayCount: String
        let value, count, incomplete: String
    }
    private static let image = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY | RTLD_LOCAL)
    // Mach-O symbol spellings of the private AX hierarchy SPI. dlsym omits
    // the Mach-O leading underscore.
    private static let function: CopyHierarchy? = {
        guard let image, let symbol = dlsym(image,"AXUIElementCopyHierarchy") else {return nil}
        return unsafeBitCast(symbol,to:CopyHierarchy.self)
    }()
    static let keys: Keys? = {
        guard let image else {return nil}
        func key(_ suffix:String) -> String? {
            guard let address=dlsym(image,"kAXUIElementCopyHierarchy"+suffix),
                  let value=address.assumingMemoryBound(to:Optional<CFString>.self).pointee else {return nil}
            return value as String
        }
        guard let skip=key("SkipInspectionForAttributesKey"),let arrays=key("ArrayAttributesKey"),
              let truncate=key("TruncateStringsKey"),let max=key("MaxArrayCountKey"),
              let value=key("ResultValueKey"),let count=key("ResultCountKey"),let incomplete=key("IncompleteResultKey") else {return nil}
        return .init(skipInspection:skip,arrayAttributes:arrays,truncateStrings:truncate,
                     maximumArrayCount:max,value:value,count:count,incomplete:incomplete)
    }()
    static var available: Bool {function != nil && keys != nil}
    // Calls are confined to MainActor, including own-process AX, as a
    // synchronous main-queue branch.
    @MainActor static func copy(_ element:AXUIElement, traversal:[String], attributes:[String], maximumArrayCount:Int) -> NSDictionary? {
        guard let function,let keys else {return nil}
        let options:[String:Any] = [keys.skipInspection:attributes,keys.arrayAttributes:traversal,
                                   keys.truncateStrings:true,keys.maximumArrayCount:maximumArrayCount]
        var result:Unmanaged<CFDictionary>?
        // A valid returned hierarchy is consumed regardless of AX status; an
        // absent/malformed result returns an empty table.
        _ = function(element,attributes as CFArray,options as CFDictionary,&result)
        return result?.takeRetainedValue() as NSDictionary?
    }
}
