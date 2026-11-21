import Foundation
import CoreFoundation
import CoreGraphics

final class AXUIElement { var role = "AXButton" }
struct EventStreamNodeAction { let name: String; let description: String }
enum AXError: Int { case success = 0, cannotComplete = -25204, attributeUnsupported = -25205, failure = -25200 }
let kAXRoleAttribute = "AXRole", kAXMenuBarItemRole = "AXMenuBarItem"
let kAXPickAction = "AXPick", kAXCancelAction = "AXCancel", kAXPressAction = "AXPress"
enum Owned {
    static var focusPrepared = false, focusFailure = false
    static var trace = [String](), delivered = [String](), descriptions = [EventStreamNodeAction]()
    static var status = AXError.success, menuSelected = false, missing = false
    static var resolutionFailure = false, fallbackFailure = false, menuFailure = false
    static var point: CGPoint?, scrolled = false, cursorShown = false, captureSequence = false
    static var positionFailure = false, moveFailure = false, policyFailure = false, waitFailure = false, roleFailure = false
    static var waits = [Double](), moves = [CGPoint](), windows = [UInt32?]()
    static var afterPosition: (() -> Void)?, afterMove: (() -> Void)?
    static func reset() {
        focusPrepared=false;focusFailure=false
        trace = []; delivered = []; descriptions = []; status = .success; menuSelected = false; missing = false
        resolutionFailure = false; fallbackFailure = false; menuFailure = false
        point=nil;scrolled=false;cursorShown=false;captureSequence=false;positionFailure=false;moveFailure=false;policyFailure=false;waitFailure=false;roleFailure=false
        waits=[];moves=[];windows=[];afterPosition=nil;afterMove=nil;CursorCapture.value=true;CursorCapture.reads=0
        AXIndex.shared.native = true; AXIndex.shared.ownerAvailable = true; AXIndex.shared.processKey = "current"
        AXIndex.shared.windowID=77
        AXIndex.shared.el = AXUIElement()
    }
}
enum AX {
    static func onElement<T>(_ el:AXUIElement,_ body:()throws->T)throws->T {
        if Owned.roleFailure {throw ServiceError(.unknownError,"owned role routing failure")}
        return try body()
    }
    static func string(_ el: AXUIElement, _ attribute: String) -> String? { el.role }
    static func secondaryActionDescriptions(_ el: AXUIElement) throws -> [EventStreamNodeAction] {
        Owned.trace.append("fallback-descriptions")
        if Owned.fallbackFailure { throw ServiceError(.unknownError,"owned fallback failure") }
        return Owned.descriptions
    }
}
enum AXMenuSessions {
    static func select(_ el: AXUIElement, bundle: String) throws -> Bool {
        Owned.trace.append("menu-select")
        if Owned.menuFailure { throw ServiceError(.unknownError,"owned menu failure") }
        return Owned.menuSelected
    }
    static func activate(_ el: AXUIElement, bundle: String) { Owned.trace.append("menu-activate") }
    static func close(_ bundle: String) { Owned.trace.append("menu-close") }
    static func closeSynthetic(_ bundle: String) { Owned.trace.append("synthetic-close") }
}
func AXUIElementPerformAction(_ el: AXUIElement, _ action: CFString) -> AXError {
    Owned.trace.append("perform"); Owned.delivered.append(action as String); return Owned.status
}
enum AXNativeElementActions {
    static func perform(_ el: AXUIElement, action: String) throws {
        let status = AXUIElementPerformAction(el, action as CFString)
        if ![AXError.success,.cannotComplete,.attributeUnsupported].contains(status) {
            throw ServiceError(.accessibilityError,"owned native action failure")
        }
    }
}
enum RequestRuntime {
    static func serialized<T>(app: String, _ body: () throws -> T) rethrows -> T { try body() }
    static func check() throws {}
    static func wait(_ duration: Double) throws {
        Owned.waits.append(duration)
        if Owned.captureSequence {Owned.trace.append("wait")}
        if Owned.waitFailure {throw ServiceError(.unknownError,"owned wait cancellation")}
    }
}
enum CursorCapture {
    static var value = true, reads = 0
    static var enabled: Bool {reads += 1;return value}
}
final class CursorOverlay {
    static let shared=CursorOverlay()
    func press(animationDuration:Double)->Bool {
        if Owned.captureSequence {Owned.trace.append("press")}
        precondition(animationDuration == 0.05)
        return Owned.cursorShown
    }
}
enum AXClickableTarget {
    static func secondaryPosition(_ el:AXUIElement,bundle:String)throws->SecondaryCursorPreparation.Position {
        precondition(Owned.focusPrepared, "focus registration must precede native position")
        if Owned.captureSequence {Owned.trace.append("position")}
        if Owned.positionFailure {throw ServiceError(.unknownError,"owned position failure")}
        Owned.afterPosition?()
        return .init(point:Owned.point,scrolled:Owned.scrolled)
    }
}
enum NativeInteractionTargetPolicy {
    static func requireAllowed(element:AXUIElement)throws {
        if Owned.captureSequence {Owned.trace.append("validate")}
        if Owned.policyFailure {throw ServiceError(.appNotAllowed,"owned denied process")}
    }
}
enum SyntheticFocusSessions { static func prepare(app: String) throws { if Owned.focusFailure { throw ServiceError(.unknownError,"owned focus preparation failure") }; Owned.focusPrepared=true } }
enum AppResolver { static func require(_ bundle: String) throws -> String { bundle } }
enum AXCapture { static func processKey(_ app: String) -> String { "current" } }
enum NativeAutomationTree { static func onMain<T>(_ body: () throws -> T) rethrows -> T { try body() } }
final class AXIndex {
    static let shared = AXIndex()
    var native = true, ownerAvailable = true, processKey = "current", el = AXUIElement()
    var windowID: UInt32 = 77
    struct Observed { let nativeTree: Int?; let processKey: String }
    func snapshot(for bundle: String) -> Observed? { Owned.trace.append("snapshot"); return .init(nativeTree: native ? 1 : nil,processKey: processKey) }
    struct Node { let actionDescriptions: [EventStreamNodeAction] }
    struct NativeWindow {let id: UInt32}
    struct AppWindow {let nativeWindow:NativeWindow}
    struct Selection {let applicationWindow:AppWindow}
    struct Snapshot {let selection:Selection}
    struct Resolved { let element: AXUIElement; let node: Node; let snapshot:Snapshot }
    struct OwnerState { let nativeOwner: Owner? }
    func state(_ bundle: String) -> OwnerState { .init(nativeOwner: ownerAvailable ? Owner(index: self) : nil) }
    struct Owner {
        let index: AXIndex
        func resolve(_ id: Int, in tree: Int, app: String, ignoreValueChange: Bool) throws -> Resolved {
            Owned.trace.append(ignoreValueChange ? "wrong-ignore-value" : "resolve")
            if Owned.resolutionFailure { throw ServiceError(.accessibilityError,"owned invalidation") }
            return .init(element: index.el,node: .init(actionDescriptions: Owned.descriptions),snapshot:.init(selection:.init(applicationWindow:.init(nativeWindow:.init(id:index.windowID)))))
        }
    }
    /* INDEX */
}
extension Actions {
    static func cursor(for bundle:String,enabled:Bool?,_ update:()->Void){if enabled ?? CursorCapture.enabled {update()}}
    static func moveCursor(to point:CGPoint,bundle:String,windowID:UInt32?)throws {
        if Owned.captureSequence {Owned.trace.append("move")}
        Owned.moves.append(point);Owned.windows.append(windowID)
        if Owned.moveFailure {throw ServiceError(.unknownError,"owned movement failure")}
        Owned.afterMove?()
    }
    static func element(from a: JSON, bundle: String) throws -> AXUIElement? {
        Owned.trace.append("legacy-element"); return Owned.missing ? nil : AXIndex.shared.el
    }
    static func run(_ action: String?, native: Bool = true, id: String? = "1") throws {
        var input: JSON = [:]
        if let action { input["action"] = action }
        if let id { input["elementID"] = ["_0": id] }
        try secondary(input,bundle: "owned.fixture",native: native)
    }
}
enum Actions {
    /* ACTIONS */
}
@main struct SecondaryDispatchTests {
    struct Input: Decodable {
        struct Action: Decodable { let raw: String; let description: String }
        let name: String; let requested: String; let actions: [Action]; let selected: String?; let missingDescription: String?
    }
    static func main() throws {
        var checks = [[String: Any]](), comparisons = [[String: Any]]()
        func check(_ ok: Bool,_ name: String) { checks.append(["name":name,"passed":ok]); print("\(ok ? "PASS" : "FAIL") secondary action \(name)") }
        func run(_ action: String?, native: Bool = true, id: String? = "1") -> ServiceError? {
            do { try Actions.run(action,native: native,id: id);return nil }
            catch let error as ServiceError { return error }
            catch { fatalError("unexpected owned error \(error)") }
        }
        func worker(_ action: String) -> ServiceError? {
            final class Reply: @unchecked Sendable {var error:ServiceError?}
            let reply=Reply(), signal=DispatchSemaphore(value:0)
            Thread.detachNewThread {
                do {try Actions.run(action)}
                catch let error as ServiceError {reply.error=error}
                catch {fatalError("unexpected worker error \(error)")}
                signal.signal()
            }
            guard signal.wait(timeout:.now()+2) == .success else {fatalError("owned worker timeout")}
            return reply.error
        }
        let rows = try JSONDecoder().decode([Input].self,from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        for row in rows {
            Owned.reset(); Owned.descriptions = row.actions.map { .init(name:$0.raw,description:$0.description) }
            let error = run(row.requested)
            let selected = Owned.delivered.first
            let passed: Bool
            if let expected = row.selected { passed = error == nil && selected == expected }
            else { passed = selected == nil && error?.code == .unknownError && error?.message == row.missingDescription }
            comparisons.append(["name":row.name,"expected":row.selected as Any? ?? NSNull(),"actual":selected as Any? ?? NSNull(),"passed":passed])
            check(passed,"matcher: \(row.name)")
        }
        Owned.reset(); Owned.descriptions = [.init(name:"AXIncrement",description:"Increment")]
        check(run("AXIncrement",native:false)==nil && Owned.delivered == ["AXIncrement"] && Owned.trace == ["legacy-element","perform"],"legacy raw AX action remains compatible")
        Owned.reset(); AXIndex.shared.native = false; Owned.descriptions = [.init(name:"CustomAX",description:"Custom label")]
        check(run("Custom label")==nil && Owned.delivered == ["CustomAX"] && Owned.trace.contains("fallback-descriptions"),"native request after legacy snapshot reads fresh descriptions")
        Owned.reset(); Owned.descriptions = [.init(name:"AXIncrement",description:"Increment")]; Owned.fallbackFailure = true
        check(run("Increment")==nil && !Owned.trace.contains("fallback-descriptions") && !Owned.trace.contains("wrong-ignore-value"),"resolved node supplies descriptions without querying unrelated live metadata")
        Owned.reset(); AXIndex.shared.native=false; Owned.fallbackFailure=true
        check(run("Increment")?.message == "owned fallback failure" && Owned.delivered.isEmpty,"fallback metadata failure propagates before action")
        Owned.reset(); Owned.descriptions=[.init(name:"AXPick",description:"Pick")]; Owned.menuSelected=true
        check(run("Pick")==nil && Owned.delivered.isEmpty && Owned.trace.last=="menu-select","translated pick retains synthetic menu shortcut")
        Owned.reset(); AXIndex.shared.el.role="AXMenuBarItem"; Owned.descriptions=[.init(name:"AXCancel",description:"Cancel")]
        check(run("Cancel")==nil && Owned.delivered.isEmpty && Owned.trace.last=="menu-close","translated cancel closes menu bar session")
        Owned.reset(); AXIndex.shared.el.role="AXMenuBarItem"; Owned.descriptions=[.init(name:"AXPress",description:"Press")]
        check(run("Press")==nil && Owned.delivered==["AXPress"] && Owned.trace.last=="menu-activate","translated press activates menu bar session")
        for status in [AXError.success,.cannotComplete,.attributeUnsupported] {
            Owned.reset(); Owned.status=status; Owned.descriptions=[.init(name:"AXIncrement",description:"Increment")]
            check(run("Increment")==nil && Owned.trace.last=="synthetic-close","native status \(status.rawValue) preserves cleanup")
        }
        Owned.reset(); Owned.status = .failure; Owned.descriptions=[.init(name:"AXIncrement",description:"Increment")]
        check(run("Increment")?.code == .accessibilityError && !Owned.trace.contains("synthetic-close"),"native AX failure propagates before cleanup")
        Owned.reset(); Owned.menuFailure=true; Owned.descriptions=[.init(name:"AXPick",description:"Pick")]
        check(run("Pick")?.message == "owned menu failure" && Owned.delivered.isEmpty,"menu shortcut failure cannot fall through to action")
        Owned.reset(); Owned.resolutionFailure=true
        check(run("Increment")?.message == "owned invalidation" && Owned.delivered.isEmpty,"owner invalidation stops before matching")
        Owned.reset(); AXIndex.shared.ownerAvailable=false
        check(run("Increment")?.code == .noActiveSession && Owned.delivered.isEmpty,"missing owner cannot execute stale action")
        Owned.reset(); AXIndex.shared.processKey="old"
        check(run("Increment")?.code == .noActiveSession && !Owned.trace.contains("resolve"),"restarted process rejected before resolving")
        for id in ["-1","01","invalid"] {
            Owned.reset();check(run("Increment",id:id)?.code == .accessibilityError && !Owned.trace.contains("resolve"),"noncanonical element ID \(id) rejected")
        }
        Owned.reset();check(run("Increment",id:nil)?.code == .accessibilityError && Owned.trace.isEmpty,"missing element ID rejected before metadata")
        Owned.reset();check(run(nil)?.code == .unhandledEvent && Owned.delivered.isEmpty,"missing action cannot execute anything")
        func setup() {
            Owned.reset();Owned.captureSequence=true;Owned.descriptions=[.init(name:"AXIncrement",description:"Increment")]
        }
        setup();Owned.point=CGPoint(x:10,y:20);Owned.cursorShown=true
        check(worker("Increment")==nil && Owned.waits == [0.05,0.05] && Owned.moves == [CGPoint(x:10,y:20)] && Owned.windows.count==1 && Owned.windows[0]==77 && Owned.trace == ["snapshot","resolve","position","move","validate","press","wait","wait","perform","synthetic-close"],"complete secondary order places, validates, presses, waits and executes")
        setup();Owned.cursorShown=false
        check(run("Increment")==nil && Owned.moves.isEmpty && Owned.waits.isEmpty && CursorCapture.reads==1,"absent point skips movement preference read; hidden cursor press does not wait")
        setup();CursorCapture.value=false;Owned.point=CGPoint(x:10,y:20);Owned.cursorShown=true
        check(run("Increment")==nil && Owned.trace == ["snapshot","resolve","position","validate","perform","synthetic-close"] && Owned.moves.isEmpty && Owned.waits.isEmpty,"disabled cursor still positions/reveals and validates target without visual work")
        setup();Owned.point=CGPoint(x:10,y:20);Owned.scrolled=true
        Owned.afterPosition={Owned.descriptions=[.init(name:"NewAX",description:"Updated")];AXIndex.shared.windowID=88;AXIndex.shared.el=AXUIElement()}
        check(worker("Updated")==nil && Owned.delivered == ["NewAX"] && Owned.trace == ["snapshot","resolve","position","move","snapshot","resolve","validate","press","perform","synthetic-close"] && Owned.windows[0]==77,"scroll refetch follows movement and uses refreshed descriptions")
        setup();Owned.scrolled=true;CursorCapture.value=false
        Owned.afterPosition={Owned.descriptions=[.init(name:"NewAX",description:"Updated")]}
        check(run("Updated")==nil && Owned.trace.filter{$0=="resolve"}.count==2 && Owned.moves.isEmpty,"scroll refetch occurs with cursor disabled and no point")
        setup();Owned.positionFailure=true
        check(run("Increment")?.message=="owned position failure" && !Owned.trace.contains("validate") && Owned.delivered.isEmpty,"position failure precedes validation, lookup and execution")
        setup();Owned.point=CGPoint(x:10,y:20);Owned.moveFailure=true;Owned.scrolled=true
        check(run("Increment")?.message=="owned movement failure" && Owned.trace.filter{$0=="resolve"}.count==1 && !Owned.trace.contains("validate") && Owned.delivered.isEmpty,"movement failure stops before refetch and execution")
        setup();Owned.policyFailure=true;Owned.point=CGPoint(x:10,y:20)
        check(run("Missing")?.code == .appNotAllowed && Owned.moves.count==1 && !Owned.trace.contains("press") && Owned.delivered.isEmpty,"actual-process denial follows placement and precedes action lookup")
        setup();Owned.point=CGPoint(x:10,y:20);Owned.cursorShown=true;Owned.waitFailure=true
        check(worker("Increment")?.message=="owned wait cancellation" && Owned.waits == [0.05] && Owned.delivered.isEmpty,"press cancellation prevents action and second delay")
        setup();Owned.point=CGPoint(x:10,y:20);Owned.afterMove={CursorCapture.value=false};Owned.cursorShown=true
        check(run("Increment")==nil && Owned.moves.count==1 && !Owned.trace.contains("press") && Owned.delivered == ["AXIncrement"],"press rereads preference after completed movement")
        setup();Owned.point=CGPoint(x:10,y:20);Owned.afterPosition={CursorCapture.value=false}
        check(run("Increment")==nil && Owned.moves.isEmpty && Owned.delivered == ["AXIncrement"],"movement preference is read after reveal")
        setup();Owned.point=CGPoint(x:10,y:20);Owned.descriptions=[.init(name:"AXPick",description:"Pick")];Owned.menuSelected=true;Owned.cursorShown=true
        check(run("Pick")==nil && Owned.moves.count==1 && !Owned.trace.contains("press") && Owned.waits.isEmpty,"menu pick shortcut follows placement and avoids ordinary press")
        setup();Owned.point=CGPoint(x:10,y:20);Owned.descriptions=[.init(name:"AXCancel",description:"Cancel")];AXIndex.shared.el.role="AXMenuBarItem";Owned.cursorShown=true
        check(run("Cancel")==nil && Owned.moves.count==1 && Owned.trace.last=="menu-close" && !Owned.trace.contains("press"),"menu cancellation follows placement and avoids ordinary press")
        setup();Owned.point=CGPoint(x:10,y:20)
        check(run("Missing")?.code == .unknownError && Owned.moves.count==1 && !Owned.trace.contains("press") && Owned.delivered.isEmpty,"invalid action still completes preparation before rejection")
        setup();Owned.cursorShown=true
        check(run("Increment")?.message=="Cursor press waiting requires a connection worker" && Owned.delivered.isEmpty && Owned.waits.isEmpty,"main thread cannot block waiting for cursor press")
        setup();Owned.roleFailure=true
        check(run("Increment")?.message=="owned role routing failure" && !Owned.trace.contains("press") && Owned.delivered.isEmpty,"role routing failure stops before press and delivery")
        Owned.reset();Owned.captureSequence=true;Owned.focusFailure=true;Owned.descriptions=[.init(name:"AXIncrement",description:"Increment")]
        check(run("Increment")?.message=="owned focus preparation failure" && !Owned.trace.contains("position") && Owned.delivered.isEmpty,"focus preparation failure prevents secondary positioning and action")
        let passed=checks.filter {$0["passed"] as? Bool == true}.count
        let record:[String:Any]=["checks":checks,"comparisons":comparisons,"cases":checks.count,"passed":passed,"failed":checks.count-passed,"matcher_cases":rows.count,"matcher_matches":comparisons.filter {$0["passed"] as? Bool == true}.count]
        try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        if passed != checks.count && !CommandLine.arguments.contains("--observe") {exit(1)}
    }
}
