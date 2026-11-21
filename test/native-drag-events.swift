import Foundation
import CoreGraphics

@main enum Tests {
    static func main() throws {
        let input=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let cases=input["cases"] as! [[String:Any]]
        var number:Int64=0,rows=[[String:Any]](),total=0
        for record in cases {
            let start=record["start"] as! [NSNumber],end=record["end"] as! [NSNumber]
            let count=(record["count"] as! NSNumber).intValue
            let button=(record["button"] as! NSNumber).uint32Value,window=(record["window"] as! NSNumber).uint32Value
            let flags=CGEventFlags(rawValue:(record["flags"] as! NSNumber).uint64Value)
            var actual=[[String:Any]]()
            for index in 1...count {
                let events=try MouseClickEventFactory.dragEvents(from:CGPoint(x:start[0].doubleValue,y:start[1].doubleValue),
                    to:CGPoint(x:end[0].doubleValue,y:end[1].doubleValue),button:button,clickCount:Int64(index),flags:flags,windowID:window,eventNumber:number)
                number += 2
                for event in [events.down]+events.motion+[events.up] {
                    actual.append(["type":event.type.rawValue,"point":[event.location.x,event.location.y],"flags":event.flags.rawValue,
                        "click_state":event.getIntegerValueField(.mouseEventClickState),"button":event.getIntegerValueField(.mouseEventButtonNumber),
                        "field_7":event.getIntegerValueField(.mouseEventSubtype),"number":event.getIntegerValueField(.mouseEventNumber),
                        "window_91":event.getIntegerValueField(.mouseEventWindowUnderMousePointer),"window_92":event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)])
                }
            }
            let expected=record["events"] as! [[String:Any]]
            let passed=(actual as NSArray).isEqual(expected as NSArray)
            rows.append(["name":record["name"]!,"passed":passed,"events":actual.count])
            print("\(passed ? "PASS":"FAIL") drag fields \(record["name"]!), \(actual.count) unposted events")
            if !passed {print("Expected \(expected)\nObserved \(actual)")}
            total += actual.count
        }
        let passed=rows.filter{$0["passed"] as? Bool==true}.count
        let output:[String:Any]=["passed":passed,"failed":rows.count-passed,"checks":rows,"events":total,
            "nsevent_constructor_replaced_by_owned_provider":true,"native_input":false]
        try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        if passed != rows.count {exit(1)}
    }
}
