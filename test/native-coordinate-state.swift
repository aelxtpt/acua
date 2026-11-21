import Foundation
import CoreGraphics

final class AXUIElement: NSObject {}
struct AXReference: Hashable {
    let identity: ObjectIdentifier
    let element: AXUIElement
    init(element: AXUIElement) { identity = ObjectIdentifier(element);self.element=element }
}
struct TreeRevisionStore<T> { mutating func invalidate() {} }
struct IPCApp {}
final class EventStreamTreeInvalidationMonitor {}
struct AXSnapshot {
    var app = "owned", bundleIdentifier: String, text = ""
    var windowOrigin = CGPoint.zero, windowSize = CGSize.zero, windowTitle = ""
    var screenshotPath: String?, geometry: ScreenshotGeometry?, windowElement: AXUIElement?
    var processKey: String, appReference = IPCApp(), native = false
    var nativeTree: NativeAutomationTree.Snapshot?
    var invalidationMonitor: EventStreamTreeInvalidationMonitor?
}
final class AXIndex {
    static var shared = AXIndex()
    private var states = [String: State](), shuttingDown = false
    private let lock = NSLock()
    /* INDEX */
}
final class Running { var processIdentifier: Int32 = 42; var isTerminated = false }
struct ResolvedApp {
    let key: String
    let running: Running
    var bundleIdentifier: String { "owned" }
    var displayName: String { "Owned" }
    var ipc: IPCApp { IPCApp() }
}
enum OwnedFailure: Error { case capture, tree, policy, cancel }
enum Owned {
    static var trace = [String](), removed = [String]()
    static var frame = CGRect(x:310,y:180,width:600,height:400), scale: CGFloat = 2
    static var sizing = ScreenshotGeometry.Sizing.native
    static var menu = false, imageError = false, treeError = false, policyError = false
    static var key = "p1", running = Running(), window = AXUIElement()
    static var app: ResolvedApp { ResolvedApp(key:key,running:running) }
    static func reset() {
        AXIndex.shared = AXIndex();trace=[];removed=[];frame=CGRect(x:310,y:180,width:600,height:400)
        scale=2;sizing = .native;menu=false;imageError=false;treeError=false;policyError=false
        key="p1";running=Running();window=AXUIElement()
    }
}
enum AppResolver { static func require(_ bundle: String) throws -> ResolvedApp { Owned.app } }
enum RequestRuntime {
    static func check() throws {}
    static func onMainThread<T>(_ body: () throws -> T) throws -> T { try body() }
}
enum Permissions { static func requireUnlockedScreen() throws {} }
let kAXTitleAttribute = "AXTitle"
func AXUIElementCreateApplication(_ pid: Int32) -> AXUIElement { AXUIElement() }
func AXUIElementSetMessagingTimeout(_ app: AXUIElement, _ seconds: Float) {}
enum AX {
    static func primaryWindow(_ app: AXUIElement) -> AXUIElement? { Owned.window }
    static func string(_ element: AXUIElement, _ attribute: String) -> String? { "Owned window" }
}
struct AXSettledWindow {
    var root: AXReference
    func isCurrent(processKey: String, window: AXUIElement?) -> Bool { true }
}
enum AXSettler { static func waitForNativeCapture(app: ResolvedApp) throws -> AXSettledWindow? { nil } }
enum StageManagerCapture { static func prepare(_ window: AXUIElement) throws {} }
enum AXMenuSessions {
    static func root(for app: ResolvedApp, application: AXUIElement) -> AXUIElement? { Owned.menu ? AXUIElement() : nil }
}
final class NativeAutomationTree {
    struct Selection { let url: URL? = nil; let invalidationMonitor: EventStreamTreeInvalidationMonitor? = nil }
    struct Snapshot { let text = "owned tree"; let selection = Selection() }
    static func onMain<T>(_ body: () throws -> T) rethrows -> T { try body() }
    func capture(app: ResolvedApp, window: AXUIElement, previous: Snapshot?, rootOverride: AXUIElement?, disableDiff: Bool) throws -> Snapshot {
        Owned.trace.append("tree");if Owned.treeError { throw OwnedFailure.tree };return Snapshot()
    }
}
enum NativeAppSnapshotImage {
    struct Settings {
        let mode: ScreenshotGeometry.Sizing
        static func current() -> Self { Owned.trace.append("settings");return Self(mode:Owned.sizing) }
        func sizing(backingScale: CGFloat) -> ScreenshotGeometry.Sizing { mode }
    }
}
enum Capture {
    struct WindowReference { let frame: CGRect; let title: String?; let windowID: UInt32? }
    struct Captured { let path: URL; let geometry: ScreenshotGeometry }
    /* PLAN */
    @MainActor static func nativeBackingScale(for frame: CGRect) -> CGFloat { Owned.trace.append("scale");return Owned.scale }
    static func nativeWindowTarget(_ window: AXUIElement, appPID: Int32) throws -> PointerTarget {
        PointerTarget(windowID:12,ownerPID:appPID,screenFrame:Owned.frame)
    }
    static func captureWindow(pid: Int32, into directory: URL?, matching reference: WindowReference?,
                              additionalWindowIDs: [UInt32], nativeAppName: String?, nativePlan: NativeGeometryPlan?) throws -> Captured {
        Owned.trace.append("capture")
        let plan = nativePlan!
        let stored = AXIndex.shared.nativeCoordinates(for:"owned",processKey:Owned.key)!
        precondition(stored.windowOrigin == plan.layout.windowOrigin && stored.pointScale == plan.layout.pointScale,
                     "Image operation started before retained geometry was updated")
        if Owned.imageError { throw OwnedFailure.capture }
        let geometry = ScreenshotGeometry(windowID:12,ownerPID:pid,screenFrame:reference!.frame,
            pixelWidth:1200,pixelHeight:800,nativeLayout:plan.layout)
        return Captured(path:URL(fileURLWithPath:"/private/tmp/owned-coordinate-image.jpg"),geometry:geometry)
    }
    static func removeTemporaryImage(_ path: String?) { if let path { Owned.removed.append(path) } }
}
enum ActionAppSnapshotURLPolicy {
    static func check(_ url: String?, for app: ResolvedApp) throws {
        Owned.trace.append("policy");if Owned.policyError { throw OwnedFailure.policy }
    }
}
enum Actions {
    struct Cursor { let windowID: UInt32 }
    static func cursorForCapture(_ bundle: String) -> Cursor? { nil }
    static func cursorIsCurrent(_ cursor: Cursor, for bundle: String) -> Bool { true }
    /* ACTION */
    static func map(_ point: CGPoint) throws -> CGPoint { try nativeCoordinatePoint(point,bundle:"owned").point }
}
enum AXCapture {
    /* CAPTURE */
    static func processKey(_ app: ResolvedApp) -> String { app.key }
    static func run(_ beforePublish: () throws -> Void = {}) throws -> AXSnapshot {
        try captureNativeCurrent(app:Owned.app,state:AXIndex.shared.state("owned"),disableDiff:false,
            enforceURLPolicy:true,settled:nil,settleBeforeCapture:false,beforePublish:beforePublish)
    }
}
@main enum NativeCoordinatesTests {
    static func main() throws {
        var rows = [[String: Any]]()
        func check(_ value: Bool, _ name: String) {
            rows.append(["name":name,"passed":value]);print("\(value ? "PASS":"FAIL") native coordinates \(name)")
        }
        func rejects(_ name: String, _ body: () throws -> Void) {
            do { try body();check(false,name) } catch { check(true,name) }
        }
        func plan(_ x: CGFloat) -> ScreenshotGeometry.NativeLayout {
            .init(requestedSize:CGSize(width:1200,height:800),windowOrigin:CGPoint(x:x,y:180),pointScale:0.5)
        }
        let index=AXIndex()
        check(index.nativeCoordinates(for:"a",processKey:"p1")==nil,"absent controller has no mapping")
        let first=try index.prepareNativeCoordinates(for:"a",processKey:"p1")
        check(index.nativePointerState(for:"a",processKey:"p1")!.position == .zero,"controller cursor starts at screenshot zero")
        try index.updateNativeCursor(CGPoint(x:17,y:23),for:"a",processKey:"p1")
        rejects("different process cannot replace controller cursor") {try index.updateNativeCursor(.zero,for:"a",processKey:"foreign")}
        let initial=index.nativeCoordinates(for:"a",processKey:"p1")!
        check(initial.windowOrigin == CGRect.null.origin && initial.pointScale==0 && initial.requestedSize == .zero,"first controller starts with a null origin and zero scale")
        try index.updateNativeCoordinates(plan(310),lease:first){true}
        let next=try index.prepareNativeCoordinates(for:"a",processKey:"p1")
        check(index.nativePointerState(for:"a",processKey:"p1")!.position == CGPoint(x:17,y:23),"same-process capture keeps screenshot cursor coordinates")
        check(index.nativeCoordinates(for:"a",processKey:"p1")!.windowOrigin.x==310,"new same-process attempt preserves the preceding plan")
        rejects("superseded attempt cannot overwrite newer geometry") {try index.updateNativeCoordinates(plan(999),lease:first){true}}
        try index.updateNativeCoordinates(plan(500),lease:next){true}
        let pointer=index.nativePointerState(for:"a",processKey:"p1")!
        check(pointer.layout.screenPoint(from:pointer.position) == CGPoint(x:508.5,y:191.5),"new capture remaps retained screenshot cursor through its new layout")
        try index.publish(AXSnapshot(bundleIdentifier:"a",processKey:"p1"),retainImage:true){true}
        check(index.nativeCoordinates(for:"a",processKey:"p1")!.windowOrigin.x==500,"first image-less snapshot does not clear already planned geometry")
        try index.publish(AXSnapshot(bundleIdentifier:"a",processKey:"p1"),retainImage:true){true}
        check(index.nativeCoordinates(for:"a",processKey:"p1")!.windowOrigin.x==500,"later image-less menu snapshot retains mapping")
        let replacement=try index.prepareNativeCoordinates(for:"a",processKey:"p2")
        check(index.nativePointerState(for:"a",processKey:"p2")!.position == .zero,"process replacement resets controller cursor")
        check(index.nativeCoordinates(for:"a",processKey:"p1")==nil && index.nativeCoordinates(for:"a",processKey:"p2")!.pointScale==0,"process replacement clears prior mapping and resets initial state")
        rejects("prior process lease cannot update replacement") {try index.updateNativeCoordinates(plan(999),lease:next){true}}
        rejects("terminated process cannot commit a plan") {try index.updateNativeCoordinates(plan(999),lease:replacement){false}}
        try index.updateNativeCoordinates(plan(600),lease:replacement){true}
        index.applicationTerminated(processKey:"p2")
        check(index.nativeCoordinates(for:"a",processKey:"p2")==nil,"termination clears a failed-capture owner even without a matching snapshot")
        let invalidated=try index.prepareNativeCoordinates(for:"a",processKey:"p3");index.invalidate("a")
        rejects("invalidated generation cannot restore coordinates") {try index.updateNativeCoordinates(plan(999),lease:invalidated){true}}
        rejects("invalidated owner cannot accept a late cursor write") {try index.updateNativeCursor(CGPoint(x:999,y:999),for:"a",processKey:"p3")}
        check(index.nativePointerState(for:"a",processKey:"p3")==nil,"invalidated owner publishes no cursor state")
        let other=try index.prepareNativeCoordinates(for:"b",processKey:"other");try index.updateNativeCoordinates(plan(900),lease:other){true}
        index.applicationTerminated(processKey:"unrelated")
        check(index.nativeCoordinates(for:"b",processKey:"other")!.windowOrigin.x==900,"unrelated termination preserves another owner")
        index.shutdown()
        check(index.nativeCoordinates(for:"b",processKey:"other")==nil,"shutdown retires all mappings")
        rejects("shutdown cannot accept cursor writes") {try index.updateNativeCursor(.zero,for:"b",processKey:"other")}
        rejects("shutdown cannot create a new coordinate owner") {_ = try index.prepareNativeCoordinates(for:"b",processKey:"other")}
        var raceOK=true
        for _ in 0..<100 {
            let concurrent=AXIndex(),lease=try concurrent.prepareNativeCoordinates(for:"a",processKey:"p")
            let value=plan(700)
            let group=DispatchGroup();group.enter()
            DispatchQueue.global().async {try? concurrent.updateNativeCoordinates(value,lease:lease){true};group.leave()}
            concurrent.invalidate("a");group.wait()
            raceOK = raceOK && concurrent.nativeCoordinates(for:"a",processKey:"p")==nil
        }
        check(raceOK,"100 update/invalidation races cannot resurrect a retired owner")
        Owned.reset();let shot=try AXCapture.run()
        let mapped=try Actions.map(CGPoint(x:100,y:80))
        check(shot.geometry?.nativeLayout?.pointScale==0.5 && mapped==CGPoint(x:360,y:220),"capture and action share the exact prepared scale and origin")
        check(Owned.trace == ["tree","settings","scale","capture","policy"],"geometry plan precedes image operation and is read once")
        Owned.menu=true;Owned.frame=Owned.frame.offsetBy(dx:200,dy:200);Owned.trace=[]
        let menu=try AXCapture.run(),menuPoint=try Actions.map(CGPoint(x:100,y:80))
        check(menu.geometry==nil && menu.screenshotPath==nil && menuPoint==CGPoint(x:360,y:220),"menu capture with no image keeps preceding coordinates despite current window movement")
        check(Owned.trace == ["tree","policy"],"menu skips settings, geometry planning and image operation")
        Owned.menu=false;Owned.imageError=true;Owned.trace=[]
        rejects("image failure propagates") {_ = try AXCapture.run()}
        let afterFailure=try Actions.map(.zero)
        check(afterFailure==Owned.frame.origin && AXIndex.shared.snapshot(for:"owned")?.geometry==nil,"failed image retains new plan independently from last published snapshot")
        let failedPlan=try Actions.map(.zero);Owned.treeError=true;Owned.frame=Owned.frame.offsetBy(dx:200,dy:200)
        rejects("tree failure propagates before image planning") {_ = try AXCapture.run()}
        check(try Actions.map(.zero)==failedPlan,"failure before geometry leaves the preceding plan intact")
        Owned.treeError=false;Owned.imageError=false;Owned.policyError=true
        rejects("post-image policy failure propagates") {_ = try AXCapture.run()}
        let afterPolicy=try Actions.map(.zero)
        check(afterPolicy==Owned.frame.origin && !Owned.removed.isEmpty,"unpublished image is cleaned while its committed coordinate state remains")
        Owned.policyError=false
        rejects("invalidation before snapshot publication interrupts capture") {_ = try AXCapture.run {AXIndex.shared.invalidate("owned");throw OwnedFailure.cancel}}
        rejects("cancelled owner cannot supply coordinates") {_ = try Actions.map(.zero)}
        Owned.reset();Owned.menu=true;_ = try AXCapture.run()
        let initialPoint=try Actions.map(CGPoint(x:12,y:30))
        check(initialPoint.x.isInfinite && initialPoint.y.isInfinite,"first image-less menu keeps the uninitialized mapping")
        do {_ = try MouseTargeting.select(at:initialPoint,orderedIDs:[12],windows:[.init(id:12,pid:42,frame:Owned.frame)],nativeErrors:true);check(false,"initial mapping must not become a physical point")}
        catch MouseTargeting.Failure.windowNotFoundAtPosition {check(true,"initial mapping reaches the no-containing-window error")}
        catch {check(false,"unexpected initial mapping error: \(error)")}
        let passed=rows.filter{$0["passed"] as? Bool==true}.count
        try JSONSerialization.data(withJSONObject:["passed":passed,"failed":rows.count-passed,"checks":rows],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if passed != rows.count {exit(1)}
    }
}
