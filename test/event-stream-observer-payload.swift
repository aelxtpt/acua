import Foundation
import ApplicationServices

@main struct Tests {
    static func main() {
        var checks=0
        func check(_ label:String,_ value:@autoclosure()->Bool) {
            precondition(value(),"FAIL: \(label)");checks += 1;print("PASS: \(label)")
        }
        typealias Observer=EventStreamNativeAXObserver
        check("nil callback userInfo bridges to an empty dictionary",Observer.decodeUserInfo(nil)?.isEmpty==true)
        let empty=NSDictionary() as CFDictionary
        check("empty native dictionary is a valid event payload",Observer.decodeUserInfo(empty)?.isEmpty==true)
        let element=AXUIElementCreateApplication(30000)
        let valid=NSDictionary(dictionary:["element":element,"text":"value" as NSString,"count":NSNumber(value:3)]) as CFDictionary
        let decoded=Observer.decodeUserInfo(valid)
        check("String keys preserve native payload values",decoded?["text"] as? String == "value" && decoded?["count"] as? Int == 3)
        check("native AX references are retained in payload",decoded?["element"].map {CFEqual($0,element)}==true)
        let malformed=NSDictionary(object:"value",forKey:NSNumber(value:1)) as CFDictionary
        check("non-String dictionary key rejects entire payload",Observer.decodeUserInfo(malformed)==nil)
        let mixed=NSMutableDictionary(dictionary:["valid":"value"]);mixed[NSNumber(value:2)]="bad"
        check("mixed-key dictionary is not compacted into a valid event",Observer.decodeUserInfo(mixed as CFDictionary)==nil)
        let nested=NSDictionary(dictionary:["nested":NSDictionary(object:"v",forKey:NSNumber(value:1))]) as CFDictionary
        check("nested dictionary keys are not constrained by outer bridge",Observer.decodeUserInfo(nested)?["nested"] is NSDictionary)
        let null=NSDictionary(dictionary:["value":NSNull()]) as CFDictionary
        check("NSNull is preserved as an object payload",Observer.decodeUserInfo(null)?["value"] is NSNull)
        print("\(checks) checks")
    }
}
