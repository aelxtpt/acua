import Foundation
import CoreGraphics

enum OwnedFailure:Error {case current}
enum Owned {
    static var trace=[String](),creationPoint:CGPoint?,creationTime:Double?,windowLocation:CGPoint?,posted:CGEvent?,pid:Int32?
    static var now:UInt64=100,factoryFailure=false,stale=false
    static func reset(){trace=[];creationPoint=nil;creationTime=nil;windowLocation=nil;posted=nil;pid=nil;now=100;factoryFailure=false;stale=false;Actions.spi=true}
}
struct DispatchTime {let uptimeNanoseconds:UInt64;static func now()->Self{Owned.trace.append("clock");return Self(uptimeNanoseconds:Owned.now)}}
final class CGEvent {
    var location:CGPoint,type:CGEventType,flags:CGEventFlags=[]
    var timestamp:UInt64=1,fields=[UInt32:Int64]()
    init(_ type:CGEventType,_ point:CGPoint){self.type=type;location=point}
    func getIntegerValueField(_ field:CGEventField)->Int64{fields[field.rawValue] ?? 0}
    func setIntegerValueField(_ field:CGEventField,value:Int64){fields[field.rawValue]=value}
    func postToPid(_ pid:Int32){Owned.trace.append("post-pid");Owned.posted=self;Owned.pid=pid}
    func post(tap:CGEventTapLocation){Owned.trace.append("post-global");Owned.posted=self}
}
enum NSEvent {
    struct EventType:Equatable {
        let rawValue:UInt
        init?(rawValue:UInt){self.rawValue=rawValue}
        static let scrollWheel=Self(rawValue:22)!,mouseMoved=Self(rawValue:5)!
    }
    struct Event {let cgEvent:CGEvent?}
    static func mouseEvent(with type:EventType,location:CGPoint,modifierFlags:CGEventFlags,timestamp:Double,
                           windowNumber:Int,context:AnyObject?,eventNumber:Int,clickCount:Int,pressure:Float)->Event? {
        Owned.trace.append("create");Owned.creationPoint=location;Owned.creationTime=timestamp;Owned.now=500
        if Owned.factoryFailure{return nil}
        let event=CGEvent(CGEventType(rawValue:UInt32(type.rawValue))!,location)
        event.timestamp=UInt64(max(0,timestamp)*1e9)
        event.setIntegerValueField(.mouseEventNumber,value:Int64(eventNumber))
        event.setIntegerValueField(.mouseEventClickState,value:Int64(clickCount))
        return Event(cgEvent:event)
    }
}
enum RequestRuntime {static func check()throws{Owned.trace.append("check")}}
enum AXPointerTarget {static func requireCurrent(_ target:PointerTarget)throws{Owned.trace.append("current");if Owned.stale{throw OwnedFailure.current}}}
enum UserInteraction {static func markSynthesized(_ event:CGEvent){Owned.trace.append("mark");event.setIntegerValueField(.eventSourceUnixProcessID,value:123)}}
enum Actions {
    static var spi=true
    private static var setWindowLocation:((CGEvent,CGPoint)->Void)?{
        guard spi else{return nil}
        return {_,point in Owned.trace.append("window-location");Owned.windowLocation=point;Owned.now=700}
    }
    /* METHODS */
    static func run(_ event:CGEvent?,native:Bool=true,target:PointerTarget?=PointerTarget(windowID:77,ownerPID:42,screenFrame:CGRect(x:310,y:180,width:600,height:400),eventPID:900),unchecked:Bool=false)throws {
        if unchecked{try postPointerEventUnchecked(event,target:target,preserveMouseIdentity:true,native:native)}
        else{try postPointerEvent(event,target:target,preserveMouseIdentity:true,native:native)}
    }
}
@main enum SenderTests {
    static func main()throws{
        var rows=[[String:Any]]()
        func check(_ ok:Bool,_ name:String){rows.append(["name":name,"passed":ok]);print("\(ok ? "PASS":"FAIL") native sender \(name)")}
        for type in [CGEventType.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.mouseMoved] {
            Owned.reset();let event=CGEvent(type,CGPoint(x:535,y:275));event.flags=[.maskShift,.maskCommand]
            for (field,value) in [(CGEventField.mouseEventNumber,Int64(301)),(.mouseEventClickState,3),(.mouseEventSubtype,3),(.mouseEventButtonNumber,7)]{event.setIntegerValueField(field,value:value)}
            try Actions.run(event)
            let result=Owned.posted!
            check(Owned.creationPoint==event.location && Owned.creationTime==0,"global point and zero construction timestamp type\(type.rawValue)")
            check(result.timestamp==700 && Owned.trace.suffix(3)==["clock","mark","post-pid"],"timestamp refreshed after preparation and immediately before posting type\(type.rawValue)")
            check(result.type==type && result.flags==event.flags && result.getIntegerValueField(.mouseEventNumber)==301 && result.getIntegerValueField(.mouseEventClickState)==3 && result.getIntegerValueField(.mouseEventSubtype)==3 && result.getIntegerValueField(.mouseEventButtonNumber)==7,"event identity and flags retained type\(type.rawValue)")
            check(Owned.pid==900 && Owned.windowLocation==CGPoint(x:225,y:95) && result.location==event.location && result.getIntegerValueField(.mouseEventWindowUnderMousePointer)==77 && result.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)==77,"separate receiving PID and both window identities with top-left local point type\(type.rawValue)")
        }
        Owned.reset();let legacy=CGEvent(.leftMouseDown,CGPoint(x:535,y:275));try Actions.run(legacy,native:false)
        check(Owned.creationPoint==CGPoint(x:225,y:305) && (Owned.creationTime ?? 0)>0 && !Owned.trace.contains("clock"),"legacy construction coordinates/time remain separate")
        Owned.reset();let target=PointerTarget(windowID:88,ownerPID:42,screenFrame:CGRect(x:-1920,y:-900,width:1000,height:700),eventPID:901)
        try Actions.run(CGEvent(.leftMouseDown,CGPoint(x:-1700,y:-600)),target:target)
        check(Owned.creationPoint==CGPoint(x:-1700,y:-600) && Owned.windowLocation==CGPoint(x:220,y:300) && Owned.pid==901,"negative display coordinates preserve global origin and remote receiver")
        Owned.reset();Owned.stale=true
        do{try Actions.run(CGEvent(.leftMouseDown,.zero));check(false,"stale current target rejects")}catch{check(Owned.posted==nil && !Owned.trace.contains("create"),"stale target fails before event construction")}
        Owned.reset();Owned.stale=true;try Actions.run(CGEvent(.leftMouseUp,CGPoint(x:535,y:275)),unchecked:true)
        check(!Owned.trace.contains("current") && Owned.posted?.type == .leftMouseUp && Owned.posted?.timestamp==700,"release cleanup bypasses stale guard and retains native delivery")
        for fault in ["nil","factory","SPI"]{
            Owned.reset();Owned.factoryFailure=fault=="factory";Actions.spi=fault != "SPI"
            do{try Actions.run(fault=="nil" ? nil:CGEvent(.leftMouseDown,.zero));check(false,"failure \(fault)")}
            catch{check(Owned.posted==nil,"failure \(fault) never posts")}
        }
        Owned.reset();try Actions.run(CGEvent(.mouseMoved,.zero),native:false,target:nil)
        check(Owned.trace.last=="post-global" && Owned.pid==nil,"legacy untargeted path remains global")
        Owned.reset();let scroll=CGEvent(.scrollWheel,CGPoint(x:535,y:275))
        scroll.setIntegerValueField(.scrollWheelEventDeltaAxis1,value:-10);scroll.setIntegerValueField(.scrollWheelEventIsContinuous,value:1)
        try Actions.run(scroll,native:false)
        check(Owned.posted?.type == .scrollWheel && Owned.posted?.getIntegerValueField(.scrollWheelEventDeltaAxis1)==(-10) && Owned.posted?.getIntegerValueField(.scrollWheelEventIsContinuous)==1,"legacy wheel data survives its temporary movement event")
        Owned.reset();let nativeWheel=CGEvent(.scrollWheel,CGPoint(x:535,y:275))
        nativeWheel.setIntegerValueField(CGEventField(rawValue:51)!,value:77)
        nativeWheel.setIntegerValueField(.scrollWheelEventPointDeltaAxis1,value:-401)
        nativeWheel.setIntegerValueField(.scrollWheelEventIsContinuous,value:1)
        nativeWheel.flags=CGEventFlags(rawValue:256)
        try Actions.run(nativeWheel)
        check(Owned.posted === nativeWheel && !Owned.trace.contains("create"),"native wheel retains original CGEvent and skips NSEvent reconstruction")
        check(Owned.posted?.getIntegerValueField(CGEventField(rawValue:51)!)==77 && Owned.posted?.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)==(-401) && Owned.posted?.flags.rawValue==256,"native wheel private window association and pixel fields survive delivery")
        check(Owned.pid==900 && Owned.windowLocation==CGPoint(x:225,y:95) && Owned.posted?.timestamp==700,"native wheel uses local window point, fresh timestamp and receiving PID")
        let passed=rows.filter{$0["passed"] as? Bool==true}.count
        try JSONSerialization.data(withJSONObject:["passed":passed,"failed":rows.count-passed,"checks":rows],options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if passed != rows.count{exit(1)}
    }
}
