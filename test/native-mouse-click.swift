import Foundation
private enum SynthesizedEventNumbers { static var shared = SynthesizedEventNumberSequence() }
import CoreGraphics

final class CGEvent {
    let name:String
    init(_ name:String){self.name=name}
}
struct PointerTarget { let windowID:UInt32=77;let eventPID:Int32=42 }
enum Fault:Error{case owned}
enum Owned {
    static var trace=[String](),values=[[String:Any]](),fault:String?,waits=0,checkpoints=0,failCheck:Int?
    static func reset(){trace=[];values=[];fault=nil;waits=0;checkpoints=0;failCheck=nil}
    static func fail(_ name:String)throws{if fault==name{throw Fault.owned}}
}
enum RequestRuntime {
    static func check()throws{Owned.checkpoints += 1;if Owned.failCheck==Owned.checkpoints{throw Fault.owned}}
    static func wait(_ seconds:Double)throws{Owned.waits += 1;Owned.trace.append("wait:\(seconds)");try Owned.fail("wait:\(Owned.waits)")}
}
enum MouseClickEventFactory {
    static func dragEvents(from start:CGPoint,to end:CGPoint,button:UInt32,clickCount:Int64,flags:CGEventFlags,windowID:UInt32,eventNumber:Int64,nextMotionEventNumber:(()->Int64)?=nil)throws->(down:CGEvent,motion:[CGEvent],up:CGEvent){
        let pair=try events(at:start,button:button,clickCount:clickCount,flags:flags,windowID:windowID,eventNumber:eventNumber)
        _ = nextMotionEventNumber?()
        return(pair.down,(0..<3).map{CGEvent("motion:\(clickCount):\($0)")},pair.up)
    }
    static func events(at point:CGPoint,button:UInt32,clickCount:Int64,flags:CGEventFlags,windowID:UInt32,eventNumber:Int64)throws->(down:CGEvent,up:CGEvent){
        Owned.trace.append("build:\(clickCount)");try Owned.fail("build:\(clickCount)")
        Owned.values.append(["count":clickCount,"button":button,"flags":flags.rawValue,"window":windowID,"number":eventNumber,"x":Double(point.x),"y":Double(point.y)])
        return(CGEvent("down:\(clickCount)"),CGEvent("up:\(clickCount)"))
    }
}
final class CursorOverlay {
    static let shared=CursorOverlay()
    func setPressed(_ pressed:Bool){Owned.trace.append("cursor:\(pressed)")}
}
enum Actions {
    /* PRODUCTION_NATIVE_MOUSE */
    static func fixture(_ input:JSON,cursor:Bool,flags:CGEventFlags=[],drag:Bool=false)throws{
        SynthesizedEventNumbers.shared = SynthesizedEventNumberSequence()
        try nativeMouseClick(at:CGPoint(x:10,y:20),options:ClickOptions(input),target:PointerTarget(),bundle:"owned.fixture",cursorVisible:cursor,additionalFlags:flags,dragTo:drag ? CGPoint(x:80,y:90) : nil)
    }
    private static func cursor(for bundle:String,enabled:Bool?,_ body:()->Void){body()}
    private static func withHeldKeys<T>(_ chord:KeyChord?,pid:Int32,_ body:(CGEventFlags)throws->T)throws->T{
        Owned.trace.append("keys-down");defer{Owned.trace.append("keys-up")}
        return try body(chord?.flags ?? [])
    }
    private static func postPointerEvent(_ event:CGEvent,target:PointerTarget,preserveMouseIdentity:Bool,native:Bool)throws{
        precondition(native);Owned.trace.append("post:\(event.name)");try Owned.fail("post:\(event.name)")
    }
    private static func postPointerEventUnchecked(_ event:CGEvent,target:PointerTarget,preserveMouseIdentity:Bool,native:Bool)throws{precondition(native);Owned.trace.append("recover:\(event.name)")}
}
@main struct NativeMouseTests {
    static func main()throws{
        var rows=[[String:Any]]();var delayMatches=0
        func check(_ ok:Bool,_ name:String){rows.append(["name":name,"passed":ok]);print("\(ok ? "PASS":"FAIL") native mouse \(name)")}
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let cases=reference["cases"] as! [[String:Any]]
        for (index,input) in cases.enumerated(){
            func duration(_ value:Any?)->Duration?{(value as? NSNumber).map{Duration(secondsComponent:0,attosecondsComponent:$0.int64Value)}}
            let kind=(input["type"] as! NSNumber).uint32Value
            let actual=NativeMouseClick.delay(mouseDown:[1,3,25].contains(kind),isLast:input["last"] as! Bool,hold:duration(input["hold"]),interval:duration(input["interval"]))
            let expected=(input["delay"] as? [String:NSNumber]).map{Duration(secondsComponent:$0["seconds"]!.int64Value,attosecondsComponent:$0["attoseconds"]!.int64Value)}
            if actual==expected{delayMatches += 1};check(actual==expected,"optional delay \(index)")
        }
        func run(_ name:String,input:JSON=[:],cursor:Bool=false,drag:Bool=false,fault:String?=nil,checkAt:Int?=nil,expected:[String],throws expectedError:Bool=false)throws{
            Owned.reset();Owned.fault=fault;Owned.failCheck=checkAt;var failed=false
            do{try Actions.fixture(input,cursor:cursor,drag:drag)}catch{failed=true}
            check(failed==expectedError && Owned.trace==expected,name)
        }
        try run("default hold is fifty milliseconds",expected:["build:1","keys-down","post:down:1","wait:0.05","post:up:1","keys-up"])
        try run("explicit zero is clamped",input:["duration":0],expected:["build:1","keys-down","post:down:1","wait:0.05","post:up:1","keys-up"])
        try run("short hold is clamped",input:["duration":0.01],expected:["build:1","keys-down","post:down:1","wait:0.05","post:up:1","keys-up"])
        try run("long hold preserved",input:["duration":0.2],expected:["build:1","keys-down","post:down:1","wait:0.2","post:up:1","keys-up"])
        try run("visible cursor waits before down and releases before up",cursor:true,expected:["build:1","keys-down","cursor:true","wait:0.05","post:down:1","wait:0.05","cursor:false","post:up:1","keys-up"])
        try run("double click batch and gap",input:["clickCount":2],expected:["build:1","build:2","keys-down","post:down:1","wait:0.05","post:up:1","wait:0.05","post:down:2","wait:0.05","post:up:2","keys-up"])
        try run("visible repeated clicks each await press",input:["clickCount":2],cursor:true,expected:["build:1","build:2","keys-down","cursor:true","wait:0.05","post:down:1","wait:0.05","cursor:false","post:up:1","wait:0.05","cursor:true","wait:0.05","post:down:2","wait:0.05","cursor:false","post:up:2","keys-up"])
        try run("later construction failure posts nothing",input:["clickCount":2],fault:"build:2",expected:["build:1","build:2"],throws:true)
        try run("pre-press cancellation posts nothing",cursor:true,checkAt:2,expected:["build:1","keys-down","keys-up"],throws:true)
        try run("animation failure releases visual only",cursor:true,fault:"wait:1",expected:["build:1","keys-down","cursor:true","wait:0.05","cursor:false","keys-up"],throws:true)
        try run("down failure never invents an up",cursor:true,fault:"post:down:1",expected:["build:1","keys-down","cursor:true","wait:0.05","post:down:1","cursor:false","keys-up"],throws:true)
        try run("hold failure releases held mouse and cursor",cursor:true,fault:"wait:2",expected:["build:1","keys-down","cursor:true","wait:0.05","post:down:1","wait:0.05","cursor:false","recover:up:1","keys-up"],throws:true)
        try run("up failure uses unchecked cleanup",fault:"post:up:1",expected:["build:1","keys-down","post:down:1","wait:0.05","post:up:1","recover:up:1","keys-up"],throws:true)
        try run("gap failure cannot send next click",input:["clickCount":2],fault:"wait:2",expected:["build:1","build:2","keys-down","post:down:1","wait:0.05","post:up:1","wait:0.05","keys-up"],throws:true)
        Owned.reset();try Actions.fixture(["clickCount":2,"mouseButton":3,"key":"Shift_L"],cursor:false)
        check(Owned.values.count==2 && Owned.values.enumerated().allSatisfy{index,value in (value["number"] as? Int64)==Int64(index) && (value["count"] as? Int64)==Int64(index+1) && (value["button"] as? UInt32)==3 && (value["window"] as? UInt32)==77 && (value["flags"] as? UInt64)==CGEventFlags.maskShift.rawValue},"event identities, target and held flags preserved across batch")
        var events=[String]();try NativeMouseClick.deliver([NativeMouseClick.Pair<String>](),hold:nil,cursor:{events.append("cursor:\($0)")},post:{events.append($0)},wait:{_ in events.append("wait")},checkpoint:{events.append("check")},recoverUp:{events.append("recover:"+$0)})
        check(events.isEmpty,"empty event batch produces no effects")
        Owned.reset(); try Actions.fixture([:],cursor:false,flags:.maskCommand)
        check((Owned.values.first?["flags"] as? UInt64)==0x100000 && Owned.trace==["build:1","keys-down","post:down:1","wait:0.05","post:up:1","keys-up"],"background command flag reaches events without an invented held key")
        Owned.reset(); try Actions.fixture(["key":"Shift_L"],cursor:false,flags:.maskCommand)
        check((Owned.values.first?["flags"] as? UInt64)==CGEventFlags.maskShift.union(.maskCommand).rawValue,"background flag unions held modifier flags")
        let dragPosts=["post:down:1","post:motion:1:0","post:motion:1:1","post:motion:1:2","post:up:1"]
        try run("native drag has no inter-event or final waits",drag:true,expected:["build:1","keys-down"]+dragPosts+["keys-up"])
        try run("native drag cursor resets before every non-down event",cursor:true,drag:true,
            expected:["build:1","keys-down","cursor:true","wait:0.05","post:down:1","cursor:false","post:motion:1:0","cursor:false","post:motion:1:1","cursor:false","post:motion:1:2","cursor:false","post:up:1","keys-up"])
        try run("native drag explicit zero has only a zero hold wait",input:["duration":0],drag:true,
            expected:["build:1","keys-down","post:down:1","wait:0.0"]+Array(dragPosts.dropFirst())+["keys-up"])
        try run("native drag explicit hold precedes motion",input:["duration":0.2],drag:true,
            expected:["build:1","keys-down","post:down:1","wait:0.2"]+Array(dragPosts.dropFirst())+["keys-up"])
        for motion in 0..<3 {
            try run("native drag motion failure releases the held button \(motion)",drag:true,fault:"post:motion:1:\(motion)",
                expected:["build:1","keys-down","post:down:1"]+(0...motion).map{"post:motion:1:\($0)"}+["recover:up:1","keys-up"],throws:true)
        }
        try run("native drag up failure uses unchecked release",drag:true,fault:"post:up:1",expected:["build:1","keys-down"]+dragPosts+["recover:up:1","keys-up"],throws:true)
        try run("native drag cancellation between down and motion recovers",cursor:true,drag:true,checkAt:4,
            expected:["build:1","keys-down","cursor:true","wait:0.05","post:down:1","cursor:false","recover:up:1","keys-up"],throws:true)
        try run("native drag later construction failure posts nothing",input:["clickCount":2],drag:true,fault:"build:2",expected:["build:1","build:2"],throws:true)
        Owned.reset();try Actions.fixture(["clickCount":2,"mouseButton":UInt32.max,"key":"Shift_L"],cursor:false,flags:.maskCommand,drag:true)
        check(Owned.values.count==2 && (Owned.values[0]["number"] as? Int64)==0 && (Owned.values[1]["number"] as? Int64)==2 && Owned.values.allSatisfy{($0["button"] as? UInt32)==UInt32.max && ($0["flags"] as? UInt64)==CGEventFlags.maskShift.union(.maskCommand).rawValue} && Owned.waits==0,
            "shared drag retains raw button, held/background flags and two identities per pair")
        let passed=rows.filter{$0["passed"] as? Bool==true}.count
        try JSONSerialization.data(withJSONObject:["passed":passed,"failed":rows.count-passed,"checks":rows,"delay_cases":cases.count,"delay_matches":delayMatches],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        if passed != rows.count{exit(1)}
    }
}
