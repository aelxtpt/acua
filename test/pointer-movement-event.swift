import Foundation

struct CGEventFlags: OptionSet { let rawValue: UInt64 }
enum CGMouseButton { case left,right,center }
enum CGEventType { case leftMouseDown,rightMouseDown,otherMouseDown,leftMouseUp,rightMouseUp,otherMouseUp,mouseMoved,leftMouseDragged,rightMouseDragged,otherMouseDragged }
enum CGEventField { case mouseEventButtonNumber,mouseEventClickState,mouseEventNumber,mouseEventSubtype,mouseEventWindowUnderMousePointer,mouseEventWindowUnderMousePointerThatCanHandleThisEvent }
final class CGEventSource { enum State { case hidSystemState };init?(stateID: State){} }
final class CGEvent {
    static var fail = false, allocations = 0, failAt: Int?
    let type: CGEventType, location: CGPoint, button: CGMouseButton
    var flags = CGEventFlags(rawValue: UInt64.max),fields = [CGEventField:Int64]()
    init?(mouseEventSource: CGEventSource?,mouseType: CGEventType,mouseCursorPosition: CGPoint,mouseButton: CGMouseButton){Self.allocations += 1;if Self.fail || Self.allocations == Self.failAt{return nil};type=mouseType;location=mouseCursorPosition;button=mouseButton}
    func setIntegerValueField(_ field: CGEventField,value:Int64){fields[field]=value}
}
/* FACTORY */
@main enum MovementEventTests {
    static func main()throws{
        var rows=[[String:Any]]()
        func check(_ pass:Bool,_ name:String){rows.append(["name":name,"passed":pass]);print("\(pass ? "PASS":"FAIL") movement event \(name)")}
        for (window,number,point) in [(UInt32(0),Int64(0),CGPoint(x:0,y:0)),(UInt32.max,Int64(1001),CGPoint(x:-50,y:22.5)),(77,Int64.max-1,CGPoint(x:212.75,y:126.25))] {
            let event=try MouseClickEventFactory.movement(at:point,windowID:window,eventNumber:number)
            check(event.type == .mouseMoved && event.location.x==point.x && event.location.y==point.y && event.button == .left,"type/point/button window=\(window)")
            check(event.flags.isEmpty && event.fields[.mouseEventClickState]==0 && event.fields[.mouseEventSubtype]==3,"unmodified non-click identity window=\(window)")
            check(event.fields[.mouseEventNumber]==number && event.fields[.mouseEventWindowUnderMousePointer]==Int64(window) && event.fields[.mouseEventWindowUnderMousePointerThatCanHandleThisEvent]==Int64(window),"counter and both window fields window=\(window)")
        }
        CGEvent.fail=true
        do{_ = try MouseClickEventFactory.movement(at:CGPoint(x:0,y:0),windowID:77,eventNumber:2);check(false,"event allocation failure propagates")}catch{check(true,"event allocation failure propagates")}
        CGEvent.fail=false
        for failure in 1...5 {
            CGEvent.allocations=0;CGEvent.failAt=failure
            let sequence=SynthesizedEventNumberSequence()
            do {
                _ = try MouseClickEventFactory.dragEvents(from:CGPoint(x:0,y:0),to:CGPoint(x:30,y:40),button:0,clickCount:1,flags:[],windowID:77,eventNumber:sequence.next(),nextMotionEventNumber:{sequence.next()})
                check(false,"drag allocation failure \(failure) stops construction")
            } catch {
                check(CGEvent.allocations==failure && sequence.next()==(failure==1 ? 1:2),"drag allocation failure \(failure) preserves counter consumption")
            }
        }
        CGEvent.allocations=0;CGEvent.failAt=nil
        let shared=SynthesizedEventNumberSequence()
        let gesture=try MouseClickEventFactory.dragEvents(from:CGPoint(x:0,y:0),to:CGPoint(x:30,y:40),button:0,clickCount:1,flags:[],windowID:77,eventNumber:shared.next(),nextMotionEventNumber:{shared.next()})
        check(gesture.down.fields[.mouseEventNumber]==0 && gesture.motion.allSatisfy{$0.fields[.mouseEventNumber]==1} && gesture.up.fields[.mouseEventNumber]==0 && shared.next()==2,"actual drag factory shares source and allocates motion identity lazily")
        let passed=rows.filter{$0["passed"] as? Bool==true}.count
        try JSONSerialization.data(withJSONObject:["passed":passed,"failed":rows.count-passed,"checks":rows],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if passed != rows.count{exit(1)}
    }
}
