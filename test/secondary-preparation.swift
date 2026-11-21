import Foundation
import CoreFoundation
import CoreGraphics

final class AXUIElement:NSObject {
    var rect:CGRect?=CGRect(x:20,y:30,width:40,height:20)
    var role="AXButton", actions=[String](), pid:Int32=42
    var pidFailure=false
}
let kAXRoleAttribute="AXRole",kAXPositionAttribute="AXPosition",kAXSizeAttribute="AXSize"
enum Owned {
    static var trace=[String](),special:CGPoint?,scrolled=false,scrollFailure=false,afterScroll:(()->Void)?
    static var ancestors=[AXUIElement](),ancestorMutation:(()->Void)?,cancelled=false
    static var applications=[Int32:String](),nilBundlePID:Int32?
    static func reset(){trace=[];special=nil;scrolled=false;scrollFailure=false;afterScroll=nil;ancestors=[];ancestorMutation=nil;cancelled=false;applications=[:];nilBundlePID=nil}
}
final class NSRunningApplication {
    let bundleIdentifier:String?
    init?(processIdentifier:Int32){
        if processIdentifier==Owned.nilBundlePID {bundleIdentifier=nil}
        else if let bundle=Owned.applications[processIdentifier]{bundleIdentifier=bundle}
        else{return nil}
    }
}
enum AccessibilityWindowSPI {
    static func actualPID(_ element:AXUIElement)throws->Int32 {
        if element.pidFailure || element.pid<=0 {throw ServiceError(.accessibilityError,"owned PID failure")}
        return element.pid
    }
}
enum RequestRuntime {static func check()throws {if Owned.cancelled {throw ServiceError(.unknownError,"owned cancellation")}}}
enum AppResolver {static func pid(for bundle:String)throws->Int32 {Owned.trace.append("pid");return 42}}
func AXUIElementCreateApplication(_ pid:Int32)->AXUIElement {AXUIElement()}
enum AX {
    static func onElement<T>(_ element:AXUIElement,_ body:()throws->T)throws->T {try body()}
    static func point(_ element:AXUIElement,_ attribute:String)->CGPoint? {Owned.trace.append("origin");return element.rect?.origin}
    static func size(_ element:AXUIElement,_ attribute:String)->CGSize? {Owned.trace.append("size");return element.rect?.size}
    static func string(_ element:AXUIElement,_ attribute:String)->String? {element.role}
    static func actionNames(_ element:AXUIElement)->[String] {element.actions}
}
enum AXClickableTarget {
    private static func frame(_ element:AXUIElement)->CGRect? {element.rect}
    private static func displays()->[CGRect] {Owned.trace.append("unexpected-display-read");return [CGRect(x:0,y:0,width:1,height:1)]}
    private static func ancestors(_ element:AXUIElement)throws->[AXUIElement] {Owned.ancestorMutation?();return [element]+Owned.ancestors}
    private static func chessPoint(_ element:AXUIElement,application:AXUIElement)throws->CGPoint? {Owned.trace.append("chess");return Owned.special}
    static func scrollToVisible(_ element:AXUIElement,frame:CGRect)throws->Bool {
        Owned.trace.append("scroll");if Owned.scrollFailure {throw ServiceError(.accessibilityError,"owned scroll failure")}
        Owned.afterScroll?();return Owned.scrolled
    }
    /* PRODUCTION_POINT_METHODS */
}

@main struct PreparationTests {
    struct Reference:Decodable {
        let geometryErrorDescription:String,systemSecurityBundles:[String]
        let pressDurationSeconds:Int64,pressDurationAttoseconds:Int64,holdDurationSeconds:Int64,holdDurationAttoseconds:Int64
    }
    static func main()throws {
        var rows=[[String:Any]]()
        func check(_ ok:Bool,_ name:String){rows.append(["name":name,"passed":ok]);print("\(ok ? "PASS":"FAIL") secondary preparation \(name)")}
        let reference=try JSONDecoder().decode(Reference.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        check(NativeInteractionTargetPolicy.systemSecurityBundles==Set(reference.systemSecurityBundles),"system-security list matches the expected array")
        check(SecondaryCursorPreparation.pressAnimationSeconds==Double(reference.pressDurationSeconds)+Double(reference.pressDurationAttoseconds)/1e18,"press animation constant matches the expected duration")
        check(SecondaryCursorPreparation.pressHoldSeconds==Double(reference.holdDurationSeconds)+Double(reference.holdDurationAttoseconds)/1e18,"press hold constant matches the expected duration")
        func position(_ element:AXUIElement,bundle:String="owned.fixture")->(SecondaryCursorPreparation.Position?,ServiceError?){
            do{return(try AXClickableTarget.secondaryPosition(element,bundle:bundle),nil)}
            catch let error as ServiceError{return(nil,error)}
            catch{fatalError("unexpected \(error)")}
        }
        Owned.reset();let element=AXUIElement()
        var result=position(element)
        check(result.1==nil && result.0?.point==CGPoint(x:40,y:40) && result.0?.scrolled==false && Owned.trace==["origin","size","scroll","origin","size"],"visible ordinary control still attempts reveal without display lookup")
        Owned.reset();Owned.scrolled=true;Owned.afterScroll={element.rect=CGRect(x:-400,y:-300,width:100,height:80)}
        result=position(element)
        check(result.1==nil && result.0?.point==CGPoint(x:-350,y:-260) && result.0?.scrolled==true,"scroll uses fresh geometry and permits negative display coordinates")
        Owned.reset();let clip=AXUIElement();clip.role="AXWindow";clip.rect=CGRect(x:0,y:0,width:10,height:10);Owned.ancestors=[clip]
        result=position(element)
        check(result.1==nil && result.0?.point==nil && result.0?.scrolled==false,"clipped center may remain absent without rejecting action preparation")
        Owned.reset();element.rect=nil
        result=position(element)
        check(result.1?.code == .unknownError && result.1?.message==reference.geometryErrorDescription && Owned.trace==["origin"],"missing initial frame uses the geometry error")
        Owned.reset();element.rect=CGRect(x:20,y:30,width:40,height:20);Owned.afterScroll={element.rect=nil}
        result=position(element)
        check(result.1?.message==reference.geometryErrorDescription && Owned.trace==["origin","size","scroll","origin"],"missing refreshed frame propagates geometry error")
        Owned.reset();element.rect=CGRect(x:20,y:30,width:40,height:20);Owned.scrollFailure=true
        result=position(element)
        check(result.1?.message=="owned scroll failure" && Owned.trace==["origin","size","scroll"],"reveal error stops before fresh point")
        Owned.reset();Owned.special=CGPoint(x:7,y:9)
        result=position(element,bundle:"com.apple.Chess")
        check(result.1==nil && result.0?.point==CGPoint(x:7,y:9) && result.0?.scrolled==false && Owned.trace==["pid","chess"],"special Chess point bypasses reveal")
        Owned.reset();result=position(element,bundle:"com.apple.Chess")
        check(result.1==nil && result.0?.point==CGPoint(x:40,y:40) && Owned.trace==["pid","chess","origin","size","scroll","origin","size"],"missing Chess point falls back to ordinary reveal")
        Owned.reset();element.rect=CGRect(x:20,y:30,width:0,height:20)
        result=position(element)
        check(result.1==nil && result.0?.point==nil && Owned.trace.contains("scroll"),"zero-size frame remains an absent point rather than missing frame")
        Owned.reset();element.rect = .infinite
        result=position(element)
        check(result.1==nil && result.0?.point==nil,"nonfinite frame cannot produce cursor coordinates")
        Owned.reset();element.role="AXScrollArea";element.rect=CGRect(x:20,y:30,width:40,height:20);Owned.ancestorMutation={element.rect = .zero}
        result=position(element)
        check(result.1==nil && result.0?.point==CGPoint(x:40,y:40),"point and self clipping share supplied final frame")
        Owned.reset();element.role="AXButton";element.rect=CGRect(x:20,y:30,width:40,height:20);Owned.cancelled=true
        result=position(element)
        check(result.1?.message=="owned cancellation" && Owned.trace.isEmpty,"cancellation precedes geometry queries")

        Owned.reset(); element.role="AXButton"; element.rect=CGRect(x:20,y:30,width:40,height:20)
        check(try AXClickableTarget.nativePoint(element,bundle:"owned.fixture")==CGPoint(x:40,y:40) && Owned.trace==["origin","size"],"native delivery point does not scroll or require a display")
        Owned.reset(); element.rect=nil
        do { _ = try AXClickableTarget.nativePoint(element,bundle:"owned.fixture"); check(false,"native delivery missing frame throws") }
        catch let error as ServiceError { check(error.message==reference.geometryErrorDescription,"native delivery missing frame throws") }
        Owned.reset(); element.rect=CGRect(x:20,y:30,width:0,height:20)
        check(try AXClickableTarget.nativePoint(element,bundle:"owned.fixture")==nil && !Owned.trace.contains("scroll"),"native delivery zero size remains offscreen")
        Owned.reset(); Owned.special=CGPoint(x:7,y:9)
        check(try AXClickableTarget.nativePoint(element,bundle:"com.apple.Chess")==CGPoint(x:7,y:9) && Owned.trace==["pid","chess"],"native delivery preserves Chess point without scrolling")

        enum Fault:Error{case stage}
        var trace=[String](),moves=[Int]()
        func prepare(point:CGPoint?=CGPoint(x:1,y:2),scrolled:Bool=false,enabled:Bool=true,fail:String?=nil)throws->Int {
            trace=[];moves=[]
            return try SecondaryCursorPreparation.prepare(1,position:{value in trace.append("position");if fail=="position"{throw Fault.stage};return .init(point:point,scrolled:scrolled)},cursorEnabled:{trace.append("flag");return enabled},move:{value,_ in trace.append("move");moves.append(value);if fail=="move"{throw Fault.stage}},refetch:{trace.append("refetch");if fail=="refetch"{throw Fault.stage};return 2},validate:{value in trace.append("validate:\(value)");if fail=="validate"{throw Fault.stage}},checkpoint:{})
        }
        check(try prepare(scrolled:true)==2 && trace==["position","flag","move","refetch","validate:2"],"orchestrator refetches after completed movement")
        check(try prepare(scrolled:true,enabled:false)==2 && trace==["position","flag","refetch","validate:2"],"disabled cursor does not suppress refetch")
        check(try prepare(point:nil,scrolled:true)==2 && trace==["position","refetch","validate:2"],"absent point skips flag read but still refetches")
        for (failure,expectedTrace) in [("position",["position"]),("move",["position","flag","move"]),("refetch",["position","flag","move","refetch"]),("validate",["position","flag","move","refetch","validate:2"])] {
            do{_ = try prepare(scrolled:true,fail:failure);check(false,"\(failure) failure stops dependent stages")}catch{check(trace==expectedTrace,"\(failure) failure stops dependent stages")}
        }
        for bundle in reference.systemSecurityBundles {
            Owned.reset();let el=AXUIElement();Owned.applications[el.pid]=bundle
            do{try NativeInteractionTargetPolicy.requireAllowed(element:el);check(false,"blocked actual process \(bundle)")}
            catch let error as ServiceError {check(error.code == .appNotAllowed && error.message=="Computer use actions are not allowed for system security process: \(bundle)","blocked actual process \(bundle)")}
        }
        for bundle in ["com.apple.finder","com.apple.SecurityAgent.extra","COM.APPLE.SECURITYAGENT",""] {
            Owned.reset();let el=AXUIElement();Owned.applications[el.pid]=bundle
            do{try NativeInteractionTargetPolicy.requireAllowed(element:el);check(true,"allowed exact nonmatch \(bundle)")}catch{check(false,"allowed exact nonmatch \(bundle)")}
        }
        Owned.reset();try NativeInteractionTargetPolicy.requireAllowed(element:AXUIElement());check(true,"unavailable process bundle is permitted")
        Owned.reset();Owned.nilBundlePID=42;try NativeInteractionTargetPolicy.requireAllowed(element:AXUIElement());check(true,"nil bundle identifier is permitted")
        Owned.reset();let failedPID=AXUIElement();failedPID.pidFailure=true
        do{try NativeInteractionTargetPolicy.requireAllowed(element:failedPID);check(false,"actual PID error propagates")}catch let error as ServiceError{check(error.code == .accessibilityError,"actual PID error propagates")}
        var focusTrace=[String]()
        _ = try SecondaryCursorPreparation.prepare(1,position:{_ in focusTrace.append("position");return .init(point:nil,scrolled:false)},cursorEnabled:{false},move:{_,_ in},refetch:{1},validate:{_ in focusTrace.append("validate")},checkpoint:{},prepareFocus:{focusTrace.append("focus")})
        check(focusTrace==["focus","position","validate"],"focus preparation precedes geometry and validation")
        focusTrace=[]
        do{_ = try SecondaryCursorPreparation.prepare(1,position:{_ in focusTrace.append("position");return .init(point:nil,scrolled:false)},cursorEnabled:{false},move:{_,_ in},refetch:{1},validate:{_ in focusTrace.append("validate")},checkpoint:{},prepareFocus:{throw Fault.stage});check(false,"focus preparation failure stops dependent stages")}
        catch{check(focusTrace.isEmpty,"focus preparation failure stops dependent stages")}
        let passed=rows.filter{$0["passed"] as? Bool==true}.count
        try JSONSerialization.data(withJSONObject:["checks":rows,"passed":passed,"failed":rows.count-passed],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        if passed != rows.count {exit(1)}
    }
}
