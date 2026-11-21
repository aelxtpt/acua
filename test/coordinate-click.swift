import Foundation
private enum SynthesizedEventNumbers { static var shared = SynthesizedEventNumberSequence() }
import CoreGraphics
import CoreFoundation

final class AXUIElement { let id: Int; init(_ id: Int) { self.id = id } }
let kAXRaiseAction = "AXRaise"
enum AXError { case success, actionUnsupported, failure }
struct AXSnapshot { let geometry: ScreenshotGeometry?; let processKey: String; let windowElement: AXUIElement? }
struct Running { let processIdentifier: Int32 }
struct ResolvedApp { let running: Running }
enum AXSettler { enum Polling { case applicationDefault, tenthSecond } }
enum Fault: Error { case owned }
enum Owned {
    static let frame = CGRect(x: 310, y: 180, width: 600, height: 400)
    static var trace = [String](), fault: String?, afterMove: (() -> Void)?, afterPost: (() -> Void)?, afterWeb: (() -> Void)?
    static var present = true, process = true, geometry = true, current = true, changed = false, visible = true, enabled = true, web = false, hit = true, menu = false, pressSupported = true
    static var pid: Int32 = 42, window: UInt32 = 77, flags: UInt64 = 0x100000
    static var points = [CGPoint](), delivered: [String: Any]?, wait = [Double](), eventNumber: Int64?, eventWindow: UInt32?
    static var recordedCursor: CGPoint?
    static var timing: CursorInteractionTiming?
    static var snapshot: AXSnapshot {
        let g = ScreenshotGeometry(windowID: 12, ownerPID: 42, screenFrame: frame, pixelWidth: 1200, pixelHeight: 800,
            nativeLayout: .init(requestedSize: CGSize(width: 1200, height: 800), windowOrigin: frame.origin, pointScale: 0.5))
        return AXSnapshot(geometry: geometry ? g : nil, processKey: "current", windowElement: AXUIElement(9))
    }
    static func phase(_ name: String) throws { trace.append(name); if fault == name { throw Fault.owned } }
    static func reset() {
        trace=[];fault=nil;afterMove=nil;afterPost=nil;afterWeb=nil
        present=true;process=true;geometry=true;current=true;changed=false;visible=true;enabled=true;web=false;hit=true;menu=false;pressSupported=true
        pid=42;window=77;flags=0x100000;points=[];delivered=nil;wait=[];eventNumber=nil;eventWindow=nil;recordedCursor=nil;timing=nil;Actions.reset()
    }
}
final class AXIndex {
    static let shared = AXIndex()
    func updateNativeCursor(_ point: CGPoint, for bundle: String, processKey: String) throws { Owned.trace.append("record-cursor");Owned.recordedCursor=point }
    func snapshot(for bundle: String) -> AXSnapshot? { Owned.trace.append("snapshot"); return Owned.present ? Owned.snapshot : nil }
    func nativeCoordinates(for bundle: String, processKey: String) -> ScreenshotGeometry.NativeLayout? {
        Owned.trace.append("mapping");return Owned.present && Owned.geometry ? Owned.snapshot.geometry?.nativeLayout : nil
    }
}
enum AppResolver {
    static func resolve(_ bundle: String) -> ResolvedApp? { Owned.process ? ResolvedApp(running: Running(processIdentifier: 42)) : nil }
    static func require(_ bundle: String) throws -> ResolvedApp {
        guard let app=resolve(bundle) else {throw ServiceError(.noActiveSession,"owned missing app")};return app
    }
}
enum AXCapture { static func processKey(_ app: ResolvedApp) -> String { "current" } }
enum Capture {
    static func currentFrame(windowID: UInt32, pid: Int32) -> CGRect? { Owned.trace.append("frame"); return Owned.current ? (Owned.changed ? Owned.frame.offsetBy(dx: 40, dy: 0) : Owned.frame) : nil }
}
func AXUIElementPerformAction(_ element: AXUIElement, _ action: CFString) -> AXError { Owned.trace.append("raise"); return .success }
final class NSRunningApplication {
    let bundleIdentifier: String?
    init?(processIdentifier: Int32) { Owned.trace.append("policy:\(processIdentifier)"); bundleIdentifier = processIdentifier == 88 ? "com.apple.SecurityAgent" : "owned.fixture" }
}
enum AccessibilityWindowSPI { static func actualPID(_ element: AXUIElement) throws -> Int32 { 42 } }
/* POLICY */
enum AXPointerTarget {
    struct Resolved { let pointer: PointerTarget; let element: AXUIElement?; let cursorWindowID: UInt32; let menu: AXUIElement? }
    static func resolveContext(at point: CGPoint, hostPID: Int32) throws -> Resolved {
        try Owned.phase("resolve"); Owned.points.append(point)
        return Resolved(pointer: PointerTarget(windowID: Owned.window, ownerPID: 42, screenFrame: Owned.frame, eventPID: Owned.pid), element: Owned.hit ? AXUIElement(5) : nil, cursorWindowID: 12, menu: Owned.menu ? AXUIElement(6) : nil)
    }
}
enum CursorCapture { static var enabled: Bool { Owned.trace.append("flag"); return Owned.enabled } }
final class CursorOverlay { static let shared = CursorOverlay(); func prepareInteraction() -> Bool { Owned.trace.append("visible"); return Owned.visible } }
enum AXNativeClickFocus {
    enum Delivery { case mouse }
    static func prepare(_ element: AXUIElement?, bundle: String, delivery: Delivery, heldKey: Bool, webShaped: () throws -> Bool) throws -> CGEventFlags {
        try Owned.phase("focus:\(element?.id ?? -1)"); let web = try webShaped(); Owned.trace.append("cached-web:\(web)")
        return CGEventFlags(rawValue: Owned.flags)
    }
}
enum AXMenuSessions { static func closeSynthetic(_ bundle: String) { Owned.trace.append("close") } }
let kAXPressAction = "AXPress"
enum AX {
    static func onElement<T>(_ element: AXUIElement, _ body: () throws -> T) rethrows -> T { try body() }
    static func actionNames(_ element: AXUIElement) -> [String] { Owned.trace.append("menu-actions"); return Owned.pressSupported ? ["AXPress"] : ["AXPick"] }
}
enum AXNativeElementActions {
    static func perform(_ element: AXUIElement, action: String) throws { try Owned.phase("menu-press:\(element.id)") }
}
struct OwnedEvent {}
enum MouseClickEventFactory {
    static func movement(at point: CGPoint, windowID: UInt32, eventNumber: Int64) throws -> OwnedEvent {
        try Owned.phase("factory"); Owned.eventNumber=eventNumber;Owned.eventWindow=windowID;return OwnedEvent()
    }
}
enum RequestRuntime {
    static func check() throws { try Owned.phase("check") }
    static func wait(_ seconds: Double) throws { try Owned.phase("wait"); Owned.wait.append(seconds) }
}
enum Actions {
    /* ACTIONS */
    static func reset() { SynthesizedEventNumbers.shared = SynthesizedEventNumberSequence(initialValue: 10) }
    static func run(_ input: JSON) throws { _ = try nativeCoordinateClick(input, bundle: "owned.fixture", options: ClickOptions(input)) }
    static func runDrag(_ from: [Any], _ to: [Any]) throws { try nativeDrag(["from":from,"to":to],bundle:"owned.fixture") }
    static func legacySnapshot() throws { _ = try coordinateSnapshot("owned.fixture") }
    static func moveCursor(to point: CGPoint, bundle: String, windowID: UInt32?, timing: CursorInteractionTiming = .finished) throws { try Owned.phase("move");precondition(windowID == 12);Owned.timing=timing;Owned.trace.append("arrived");Owned.afterMove?() }
    static func cursor(for bundle: String, enabled: Bool? = nil, _ update: () -> Void) { Owned.trace.append("cursor:\(enabled == true)");update() }
    static func webClickShape(_ element: AXUIElement, bundle: String) throws -> Bool { try Owned.phase("web:\(element.id)");let value=Owned.web;Owned.afterWeb?();return value }
    static func postPointerEvent(_ event: OwnedEvent, target: PointerTarget?, preserveMouseIdentity: Bool = false, native: Bool = false) throws {
        try Owned.phase("post");precondition(preserveMouseIdentity && native && target?.eventPID == Owned.pid);Owned.afterPost?()
    }
    static func nativeMouseClick(at point: CGPoint, options: ClickOptions, target: PointerTarget, bundle: String, cursorVisible: Bool, additionalFlags: CGEventFlags = [], dragTo: CGPoint? = nil) throws {
        try Owned.phase("click");Owned.delivered=["point":[point.x,point.y],"count":options.count,"button":options.button,"duration":options.duration,"explicit":options.hasExplicitDuration,"held":options.chord != nil,"visible":cursorVisible,"flags":additionalFlags.rawValue,"pid":target.eventPID]
        if let dragTo {Owned.delivered?["dragTo"]=[Double(dragTo.x),Double(dragTo.y)]}
    }
}
@main enum CoordinateTests {
    static func main() throws {
        var rows = [[String: Any]]()
        func check(_ pass: Bool, _ name: String) { rows.append(["name":name,"passed":pass]);print("\(pass ? "PASS":"FAIL") coordinate click \(name)");if !pass {print("Observed points=\(Owned.points) delivered=\(String(describing:Owned.delivered)) trace=\(Owned.trace)")} }
        func input(_ options: JSON = [:], point: [Any] = [240,180]) -> JSON { var a=options;a["at"]=["coordinate":["_0":point]];return a }
        func before(_ a: String, _ b: String) -> Bool { guard let x=Owned.trace.firstIndex(of:a),let y=Owned.trace.firstIndex(of:b) else{return false};return x<y }
        Owned.reset();try Actions.run(input())
        check(Owned.timing == .closeEnough,"ordinary coordinate click requests close-enough timing")
        check(Owned.points == [CGPoint(x:430,y:270)] && Owned.delivered != nil,"global point uses retained native scale and origin")
        check(!Owned.trace.contains("raise") && !Owned.trace.contains("frame") && Owned.trace.contains("mapping"),"native coordinates use retained mapping without raising or revalidating the old image window")
        check(before("policy:42","move") && before("arrived","post") && before("post","web:5") && before("web:5","visible") && before("visible","flag") && before("flag","focus:5") && before("focus:5","click"),"security then awaited movement then physical movement then focus and click")
        check(Owned.eventNumber==10 && Owned.eventWindow==77 && Owned.wait==[0.01],"movement consumes one shared identity and awaits ten milliseconds")
        check(Owned.delivered?["flags"] as? UInt64 == 0x100000 && Owned.trace.last=="close","focus flags reach native mouse batch then synthetic menu cleanup")
        for enabled in [false,true] {for visible in [false,true] {
            Owned.reset();Owned.enabled=enabled;Owned.visible=visible;try Actions.run(input(["clickCount":3,"mouseButton":1,"duration":0.1,"key":"Shift_L"]))
            let d=Owned.delivered!
            check(d["visible"] as? Bool == (visible && enabled) && d["count"] as? Int == 3 && d["button"] as? Int == 1 && d["duration"] as? Double == 0.1 && d["explicit"] as? Bool == true && d["held"] as? Bool == true && Owned.trace.filter{$0=="post"}.count==1 && Owned.trace.contains("arrived"),"one movement for repeated clicks; options retained enabled=\(enabled) visible=\(visible)")
        }}
        for phase in ["move","post","web"] {
            Owned.reset();Owned.enabled=true
            let disable = { Owned.enabled=false }
            if phase=="move"{Owned.afterMove=disable}else if phase=="post"{Owned.afterPost=disable}else{Owned.afterWeb=disable}
            try Actions.run(input())
            check(Owned.delivered?["visible"] as? Bool == false && before("arrived","flag"),"fresh flag after \(phase)")
        }
        Owned.reset();Owned.enabled=false;Owned.afterMove={Owned.enabled=true};try Actions.run(input())
        check(Owned.delivered?["visible"] as? Bool == true && Owned.trace.filter{$0=="flag"}.count==1,"disabled preference does not skip coordinate movement and can change before press")
        Owned.reset();Owned.web=true;Owned.afterWeb={Owned.web=false};try Actions.run(input())
        check(Owned.trace.contains("cached-web:true") && Owned.trace.filter{$0=="web:5"}.count==1,"web shape computed before focus and retained")
        Owned.reset();Owned.hit=false;try Actions.run(input())
        check(Owned.trace.contains("focus:-1") && Owned.trace.contains("cached-web:false") && !Owned.trace.contains("web:5"),"absent hit remains absent with false web shape")
        Owned.reset();Owned.pid=900;try Actions.run(input())
        check(Owned.trace.contains("policy:900") && Owned.delivered?["pid"] as? Int32 == 900,"hosted event PID is checked and retained independently of geometry owner")
        Owned.reset();Owned.menu=true;Owned.enabled=false;try Actions.run(input(["clickCount":3,"mouseButton":2]))
        check(before("policy:42","move") && before("arrived","menu-actions") && Owned.trace.contains("menu-press:5") && Owned.delivered==nil && Owned.eventNumber==nil && Owned.wait.isEmpty,
            "typed menu still validates and awaits cursor, ignores button/count, then presses the hit without physical movement")
        check(!Owned.trace.contains("flag") && !Owned.trace.contains("visible") && !Owned.trace.contains("web:5") && !Owned.trace.contains("focus:5") && !Owned.trace.contains("close"),
            "menu branch skips ordinary web/focus/press flags and synthetic menu cleanup")
        for options: JSON in [["duration":0],["duration":0.2],["key":"Shift_L"]] {
            Owned.reset();Owned.menu=true
            do { try Actions.run(input(options));check(false,"unsupported menu option rejected") }
            catch let error as ServiceError {check(error.code == .unknownError && error.message == "Menu mouse action not supported" && Owned.trace.contains("arrived") && !Owned.trace.contains("menu-actions") && !Owned.trace.contains("post"),"unsupported menu options reject after cursor arrival before actions or posting \(options)")}
        }
        for missingHit in [false,true] {
            Owned.reset();Owned.menu=true;Owned.hit = !missingHit;Owned.pressSupported=false
            do { try Actions.run(input());check(false,"unpressable menu hit rejected") }
            catch let error as ServiceError {check(error.message == "Failed to click menu item" && Owned.delivered==nil && !Owned.trace.contains("post"),"missing or AXPick-only menu hit fails without mouse fallback missing=\(missingHit)")}
        }
        Owned.reset();Owned.pid=88
        do{try Actions.run(input());check(false,"security process rejected before movement")}catch{check(!Owned.trace.contains("move") && !Owned.trace.contains("post") && Owned.delivered==nil,"security process rejected before movement")}
        check(Owned.recordedCursor != nil && before("record-cursor","resolve"),"coordinate position persists before later target-policy failure")
        for phase in ["resolve","move","check","factory","post","wait","web:5","focus:5","click"] {
            Owned.reset();Owned.fault=phase
            do{try Actions.run(input());check(false,"failure boundary \(phase)")}catch{check(Owned.delivered==nil && !Owned.trace.contains("close"),"failure boundary \(phase)")}
        }
        for missing in ["snapshot","geometry","process"] {
            Owned.reset()
            switch missing {case "snapshot":Owned.present=false;case "geometry":Owned.geometry=false;case "process":Owned.process=false;case "frame":Owned.current=false;default:Owned.changed=true}
            do{try Actions.run(input());check(false,"unavailable captured context \(missing)")}catch{check(!Owned.trace.contains("resolve") && !Owned.trace.contains("move"),"unavailable captured context \(missing)")}
        }
        for stale in ["frame","changed"] {
            Owned.reset();if stale=="frame"{Owned.current=false}else{Owned.changed=true}
            try Actions.run(input())
            check(Owned.delivered != nil && !Owned.trace.contains("frame"),"retained native mapping survives old image window \(stale); current target resolution owns validation")
        }
        for point: [Any] in [[],[1],[1,2,3],[true,2],["x",2],[Double.infinity,2]] {
            Owned.reset();do{try Actions.run(input(point:point));check(false,"malformed coordinate \(point)")}catch{check(Owned.delivered==nil && !Owned.trace.contains("move"),"malformed coordinate \(point)")}
        }
        for (raw,expected) in [([-20,180],CGPoint(x:300,y:270)),([1200,800],CGPoint(x:910,y:580)),([1400,-40],CGPoint(x:1010,y:160))] {
            Owned.reset();try Actions.run(input(point:raw))
            check(Owned.points==[expected],"native mapping permits selection outside image \(raw)")
        }
        Owned.reset();try Actions.legacySnapshot();check(Owned.trace.contains("raise") && Owned.trace.filter{$0=="frame"}.count==2,"legacy snapshot retains raise and post-raise validation")
        let shifted = ScreenshotGeometry(windowID:1,ownerPID:42,screenFrame:CGRect(x:-1920,y:-900,width:1001,height:701),pixelWidth:1000,pixelHeight:700,nativeLayout:.init(requestedSize:CGSize(width:1000.2,height:700.4),windowOrigin:CGPoint(x:-1920,y:-900),pointScale:1.001))
        let mapped=try shifted.nativeScreenPoint(from:CGPoint(x:999,y:699))
        check(abs(mapped.x - (-920.001))<1e-9 && abs(mapped.y - (-200.301))<1e-9,"native mapping ignores rounded image dimensions and preserves negative display origin")
        for point in [CGPoint(x:CGFloat.nan,y:0),CGPoint(x:0,y:CGFloat.infinity)] {
            do{_ = try shifted.nativeScreenPoint(from:point);check(false,"nonfinite native mapping rejected")}catch{check(true,"nonfinite native mapping rejected")}
        }
        Owned.reset();try Actions.run(input(point:[240.9,180.9]))
        check(Owned.points==[CGPoint(x:430,y:270)],"native click truncates screenshot coordinates to integer toward zero before scaling")
        Owned.reset();Owned.current=false;try Actions.runDrag([240.9,-180.9],[-21.9,1400.9])
        check(Owned.timing == .finished,"native drag requests completed cursor motion before delivery")
        check(Owned.points==[CGPoint(x:430,y:90)] && Owned.delivered?["dragTo"] as? [Double]==[299.5,880],"native drag maps truncated endpoints once without clipping the destination to the old image")
        check(!Owned.trace.contains("raise") && !Owned.trace.contains("snapshot") && !Owned.trace.contains("frame") && Owned.trace.filter{$0=="mapping"}.count==2 && before("policy:42","move") && before("arrived","post") && before("focus:5","click"),"native drag uses shared security, awaited movement, focus and delivery without activation/raise")
        Owned.reset();Owned.pid=900;Owned.enabled=false;try Actions.runDrag([10,20],[30,40])
        check(Owned.delivered?["pid"] as? Int32==900 && Owned.delivered?["visible"] as? Bool==false && Owned.delivered?["count"] as? Int==1 && Owned.delivered?["button"] as? Int==0 && Owned.delivered?["explicit"] as? Bool==false,"public drag uses left/count1/no hold and preserves hosted receiving PID and live cursor preference")
        Owned.reset();Owned.menu=true;try Actions.runDrag([10,20],[30,40])
        check(Owned.trace.contains("menu-press:5") && !Owned.trace.contains("post") && Owned.delivered==nil,"selected concrete menu keeps AXPress branch even with drag destination")
        for bad: [Any] in [[],[1],[1,2,3],[true,2],["x",2],[Double.infinity,2],[Double.greatestFiniteMagnitude,2]] {
            Owned.reset();do{try Actions.runDrag([1,2],bad);check(false,"malformed drag destination rejected")}catch{check(Owned.delivered==nil && !Owned.trace.contains("resolve") && !Owned.trace.contains("move"),"malformed or unrepresentable native drag destination rejects before movement \(bad)")}
        }
        for (raw,expected) in [(1.9,1.0),(-1.9,-1.0),(0.9,0.0),(-0.9,0.0),(-0.0,0.0),(Double(Int64.min),Double(Int64.min)),(Double(Int64.max).nextDown,Double(Int64.max).nextDown)] {
            let converted=try NativeCoordinateConversion.truncate(CGPoint(x:raw,y:raw))
            check(converted.x==expected && converted.y==expected,"native integer conversion boundary \(raw)")
        }
        for raw in [Double(Int64.min).nextDown,Double(Int64.max),Double.nan,Double.infinity,-Double.infinity] {
            do{_ = try NativeCoordinateConversion.truncate(CGPoint(x:raw,y:0));check(false,"native unrepresentable coordinate rejected")}
            catch{check(true,"native unrepresentable coordinate rejected without an integer trap \(raw)")}
        }
        let passed=rows.filter{$0["passed"] as? Bool==true}.count
        try JSONSerialization.data(withJSONObject:["cases":rows.count,"passed":passed,"failed":rows.count-passed,"checks":rows],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if passed != rows.count{exit(1)}
    }
}
