import Foundation
import CoreGraphics

final class AXUIElement { let id: Int; init(_ id: Int) { self.id = id } }
struct Running { let processIdentifier: Int32 = 42 }
struct App { let running = Running() }
struct OwnedEvent { let kind: String }
enum Fault: Error { case injected }
let kAXPositionAttribute = "AXPosition", kAXSizeAttribute = "AXSize"
enum Owned {
    static var trace = [String](), fault: String?, layout = makeLayout(), position = CGPoint(x: 10, y: 20)
    static var frame: CGRect? = CGRect(x: 320, y: 200, width: 250, height: 401.5)
    static var secondaryPoint: CGPoint? = CGPoint(x: 535.25, y: 275.75), clickablePoint: CGPoint? = CGPoint(x: 535.25, y: 275.75)
    static var enabled = true, scrolled = false, menu = false, available = true
    static var pid: Int32 = 900, resolved = [CGPoint](), moved = [CGPoint](), physical = [CGPoint]()
    static var wheelPoint: CGPoint?, wheelDelta: [Int64]?, wheelWindow: UInt32?, waits = [Double](), identifiers = [Int64]()
    static var normalizedID: String?, afterMove: (() -> Void)?, afterResolve: (() -> Void)?, afterClickable: (() -> Void)?
    static func makeLayout() -> ScreenshotGeometry.NativeLayout {
        .init(requestedSize: CGSize(width: 1200, height: 800), windowOrigin: CGPoint(x: 310, y: 180), pointScale: 0.5,
              visibleSize: CGSize(width: 913.125, height: 641.5))
    }
    static func phase(_ name: String) throws { trace.append(name); if fault == name { throw Fault.injected } }
    static func reset() {
        trace=[];fault=nil;layout=makeLayout();position=CGPoint(x:10,y:20)
        frame=CGRect(x:320,y:200,width:250,height:401.5)
        secondaryPoint=CGPoint(x:535.25,y:275.75);clickablePoint=secondaryPoint
        enabled=true;scrolled=false;menu=false;available=true;pid=900
        resolved=[];moved=[];physical=[];wheelPoint=nil;wheelDelta=nil;wheelWindow=nil;waits=[];identifiers=[]
        normalizedID=nil;afterMove=nil;afterResolve=nil;afterClickable=nil;Actions.reset()
    }
}
enum AppResolver { static func require(_ bundle: String) throws -> App { App() } }
enum AXCapture { static func processKey(_ app: App) -> String { "owned-process" } }
final class AXIndex {
    static let shared = AXIndex()
    func updateNativeCursor(_ point: CGPoint, for bundle: String, processKey: String) throws {
        try Owned.phase("store"); guard Owned.available else { throw Fault.injected }; Owned.position = point
    }
    func nativePointerState(for bundle: String, processKey: String) -> (layout: ScreenshotGeometry.NativeLayout, position: CGPoint)? {
        Owned.trace.append("state"); return Owned.available ? (Owned.layout, Owned.position) : nil
    }
}
enum AXPointerTarget {
    struct Resolved { let pointer: PointerTarget; let cursorWindowID: UInt32; let menu: AXUIElement? }
    static func resolveContext(at point: CGPoint, hostPID: Int32) throws -> Resolved {
        try Owned.phase("resolve"); Owned.resolved.append(point); Owned.afterResolve?()
        return Resolved(pointer: PointerTarget(windowID:77,ownerPID:42,screenFrame:CGRect(x:310,y:180,width:600,height:400),eventPID:Owned.pid),cursorWindowID:12,menu:Owned.menu ? AXUIElement(9):nil)
    }
}
enum NativeInteractionTargetPolicy {
    static func requireAllowed(processIdentifier: Int32) throws { try Owned.phase("PID-policy"); if processIdentifier == 88 { throw Fault.injected } }
    static func requireAllowed(element: AXUIElement) throws { try Owned.phase("element-policy") }
}
enum AXClickableTarget {
    static func secondaryPosition(_ element: AXUIElement, bundle: String) throws -> SecondaryCursorPreparation.Position {
        try Owned.phase("prepare-position"); return .init(point: Owned.secondaryPoint, scrolled: Owned.scrolled)
    }
    static func nativePoint(_ element: AXUIElement, bundle: String) throws -> CGPoint? {
        try Owned.phase("clickable"); let point = Owned.clickablePoint; Owned.afterClickable?(); return point
    }
}
enum CursorCapture { static var enabled: Bool { Owned.trace.append("flag"); return Owned.enabled } }
enum SyntheticFocusSessions { static func prepare(app: App) throws { try Owned.phase("focus") } }
enum AX {
    static func onElement<T>(_ element: AXUIElement, _ body: () throws -> T) rethrows -> T { try body() }
    static func rectangle(_ element: AXUIElement, _ attribute: String) -> CGRect? { Owned.trace.append("frame"); return Owned.frame }
    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? { nil }
    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? { nil }
}
enum MouseClickEventFactory {
    static func movement(at point: CGPoint, windowID: UInt32, eventNumber: Int64) throws -> OwnedEvent {
        try Owned.phase("move-factory"); Owned.physical.append(point); Owned.identifiers.append(eventNumber)
        return OwnedEvent(kind:"move")
    }
}
enum ScrollEventFactory {
    static func event(at point: CGPoint, deltaX: Int64, deltaY: Int64, windowID: UInt32?) throws -> OwnedEvent {
        try Owned.phase("wheel-factory");Owned.wheelPoint=point;Owned.wheelDelta=[deltaX,deltaY];Owned.wheelWindow=windowID
        return OwnedEvent(kind:"wheel")
    }
}
enum RequestRuntime {
    static func check() throws { try Owned.phase("check") }
    static func wait(_ seconds: Double) throws { try Owned.phase("wait");Owned.waits.append(seconds) }
}
enum SynthesizedEventNumbers {
    static var shared = SynthesizedEventNumberSequence(initialValue: 10)
}
enum Actions {
    struct SecondaryTarget { let element: AXUIElement; let windowID: UInt32? }
    static func reset() { SynthesizedEventNumbers.shared = SynthesizedEventNumberSequence(initialValue: 10) }
    static func run(_ input: JSON) throws { try nativeScroll(input,bundle:"owned") }
    static func send() throws { try nativeSendScroll(deltaX:0,deltaY:99,bundle:"owned") }
    private static func secondaryTarget(_ input: JSON, bundle: String, native: Bool) throws -> SecondaryTarget {
        try Owned.phase("target");Owned.normalizedID=elementIndex(from:input)
        return SecondaryTarget(element:AXUIElement(Owned.scrolled && Owned.trace.filter{$0=="target"}.count>1 ? 2:1),windowID:12)
    }
    private static func moveCursor(to point: CGPoint, bundle: String, windowID: UInt32?) throws {
        try Owned.phase("move");Owned.moved.append(point);Owned.trace.append("arrived");Owned.afterMove?()
    }
    private static func postPointerEvent(_ event: OwnedEvent?, target: PointerTarget?, preserveMouseIdentity: Bool = false, native: Bool = false) throws {
        guard native, target?.eventPID == Owned.pid else { throw Fault.injected }
        try Owned.phase(event!.kind+"-post")
    }
    /* METHODS */
}

@main enum ScrollDispatchTests {
    static func main() throws {
        var rows = [[String: Any]]()
        func check(_ value: Bool, _ name: String) { rows.append(["name":name,"passed":value]);print("\(value ? "PASS":"FAIL") scroll dispatch \(name)") }
        func coordinate(_ direction: String = "down", pages: Double = 1) -> JSON { ["at":["coordinate":["_0":[100.75,80.25]]],"direction":direction,"pages":pages] }
        func element(_ direction: String = "down", pages: Double = 1, id: String = "01") -> JSON { ["at":["elementID":["_0":id]],"direction":direction,"pages":pages] }
        func before(_ a: String, _ b: String) -> Bool { (Owned.trace.firstIndex(of:a) ?? 999) < (Owned.trace.firstIndex(of:b) ?? -1) }
        Owned.reset();try Actions.run(coordinate())
        check(Owned.position == CGPoint(x:100,y:80) && Owned.moved == [CGPoint(x:360,y:220)],"coordinate truncates before layout conversion and awaits cursor")
        check(Owned.wheelDelta == [0,-642] && Owned.wheelPoint == CGPoint(x:360,y:220),"coordinate uses exact visible height and page rounding")
        check(Owned.resolved == [CGPoint(x:360,y:220),CGPoint(x:360,y:220)] && Owned.wheelWindow == 77,"move and scroll independently resolve current target")
        check(before("store","resolve") && before("PID-policy","move") && before("arrived","move-post") && before("move-post","wheel-post"),"store, target policy, arrival, movement and wheel ordering")
        check(Owned.waits == [0.01,0.01] && Owned.identifiers == [10],"one movement identity, ten milliseconds after both batches including final wheel")
        check(!Owned.trace.contains("focus") && !Owned.trace.contains("flag") && !Owned.trace.contains("frame"),"coordinate path skips element focus and feature flag")
        for (direction, expected): (String,[Int64]) in [("up",[0,642]),("down",[0,-642]),("left",[-913,0]),("right",[913,0])] {
            Owned.reset();try Actions.run(coordinate(direction));check(Owned.wheelDelta == expected,"direction and dimension \(direction)")
        }
        Owned.reset();Owned.enabled=false;try Actions.run(coordinate())
        check(Owned.moved.count == 1 && Owned.physical.count == 1,"coordinate preparation moves even with cursor preference disabled")
        Owned.reset();Owned.menu=true;try Actions.run(coordinate())
        check(Owned.moved.count == 1 && Owned.physical.isEmpty && Owned.waits == [0.01] && Owned.wheelDelta == [0,-642],"menu skips physical movement but still delivers wheel")
        Owned.reset();try Actions.run(element())
        check(Owned.normalizedID == "1" && before("focus","prepare-position") && before("element-policy","frame") && before("frame","clickable"),"numeric element identifier normalized and frame read after full preparation")
        check(Owned.moved == [CGPoint(x:535.25,y:275.75),CGPoint(x:535,y:275.5)] && Owned.position == CGPoint(x:450,y:191),"element preparation followed by independent quantized moveMouse")
        check(Owned.wheelDelta == [0,-402] && Owned.wheelPoint == CGPoint(x:535,y:275.5),"element extent and quantized global event point")
        Owned.reset();Owned.enabled=false;try Actions.run(element())
        check(Owned.moved.count == 1 && Owned.physical.count == 1,"element second move runs independently of cursor preference")
        Owned.reset();Owned.scrolled=true;try Actions.run(element())
        check(Owned.trace.filter{$0=="target"}.count == 2 && before("prepare-position","element-policy"),"revealed element is refetched before validation and extent lookup")
        Owned.reset();Owned.secondaryPoint=nil;Owned.clickablePoint=nil;try Actions.run(element())
        check(Owned.position == CGPoint(x:10,y:20) && Owned.moved.isEmpty && Owned.physical.isEmpty && Owned.wheelPoint == CGPoint(x:315,y:190),"nil clickable point keeps preceding controller cursor")
        Owned.reset();Owned.frame=nil;Owned.clickablePoint=nil;try Actions.run(element("left"))
        check(Owned.wheelDelta == [-913,0],"missing element frame falls back to retained visible extent")
        Owned.reset();Owned.frame=CGRect(x:0,y:0,width:20,height:30);try Actions.run(element("down",pages:0.005))
        check(Owned.wheelDelta == [0,-1],"small element uses minimum extent before fractional rounding")
        Owned.reset();Owned.afterClickable={Owned.frame=CGRect(x:0,y:0,width:999,height:999)};try Actions.run(element())
        check(Owned.wheelDelta == [0,-402],"extent captured before clickable point lookup is retained")
        Owned.reset();Owned.afterMove={Owned.layout = .init(requestedSize:CGSize(width:100,height:100),windowOrigin:CGPoint(x:-800,y:-500),pointScale:2,visibleSize:CGSize(width:201.25,height:302.5))};try Actions.run(coordinate())
        check(Owned.wheelPoint == CGPoint(x:-600,y:-340) && Owned.wheelDelta == [0,-303],"coordinate extent and delivery re-read layout after cursor preparation")
        Owned.reset();Owned.afterResolve={Owned.layout = .init(requestedSize:CGSize(width:100,height:100),windowOrigin:CGPoint(x:-800,y:-500),pointScale:2)};try Actions.send()
        check(Owned.resolved == [CGPoint(x:315,y:190)] && Owned.wheelPoint == CGPoint(x:-780,y:-460),"low-level factory reads current mapping independently from target resolution")
        for fault in ["store","resolve","PID-policy","move","check","move-factory","move-post","wait","wheel-factory"] {
            Owned.reset();Owned.fault=fault
            do { try Actions.run(coordinate());check(false,"fault \(fault)") }
            catch { check(!Owned.trace.contains("wheel-post"),"fault \(fault) never delivers wheel") }
        }
        for fault in ["target","focus","prepare-position","element-policy","clickable"] {
            Owned.reset();Owned.fault=fault
            do { try Actions.run(element());check(false,"element fault \(fault)") }
            catch { check(!Owned.trace.contains("wheel-factory"),"element fault \(fault) stops before wheel creation") }
        }
        Owned.reset();Owned.available=false
        do { try Actions.run(coordinate());check(false,"absent state") } catch { check(Owned.resolved.isEmpty && Owned.wheelDelta==nil,"absent controller rejects before target selection") }
        Owned.reset();Owned.pid=88
        do { try Actions.run(coordinate());check(false,"blocked PID") } catch { check(Owned.moved.isEmpty && Owned.wheelDelta==nil,"blocked receiving PID fails before cursor or wheel") }
        for pages in [0.0,-1] {
            Owned.reset();do { try Actions.run(coordinate(pages:pages));check(false,"invalid pages") }
            catch let error as ServiceError {check(error.code == .unknownError && error.message == "invalidScrollPages" && Owned.trace.isEmpty,"invalid pages error precedes all preparation")}
        }
        Owned.reset();do { try Actions.run(element(id:"bad"));check(false,"invalid element ID") }
        catch let error as ServiceError {check(error.code == .unknownError && error.message == "invalidElementID" && Owned.trace.isEmpty,"invalid element identifier error precedes all preparation")}
        for value: Any in [true,"1",Double.infinity,Double.nan] {
            Owned.reset();var input=coordinate();input["pages"]=value
            do { try Actions.run(input);check(false,"malformed pages") }
            catch {check(Owned.trace.isEmpty,"malformed raw pages cannot default to one page")}
        }
        let passed=rows.filter{$0["passed"] as! Bool}.count
        try JSONSerialization.data(withJSONObject:["passed":passed,"failed":rows.count-passed,"checks":rows],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if passed != rows.count { exit(1) }
    }
}
