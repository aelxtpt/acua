import Foundation
import CoreGraphics

private final class Node {
    var attributes: [String: String] = [:]
    var references: [String: Node] = [:]
    var arrays: [String: [Node]] = [:]
    var pid: Int32?
    var windowID: UInt32?
    var bounds: CGRect?
    var url: URL?
    init(_ role: String? = nil, title: String? = nil) {
        attributes["AXRole"] = role; attributes["AXTitle"] = title
    }
}

@MainActor
private final class Backend: EventStreamContextBackend {
    var windows: [UInt32: EventStreamNativeWindow] = [:]
    var candidates: [EventStreamNativeWindow] = []
    var desktops: [EventStreamNativeWindow] = []
    var apps: [Int32: Node] = [:]
    var appRecords: [Int32: EventStreamApp] = [:]
    var desktopIconLevel = -10
    var frontmostProcessIdentifier: Int32? = 10
    var trackedFrontmostOverride: (() -> Int32?)?
    var trackedFrontmostProcessIdentifier: Int32? {
        if let trackedFrontmostOverride { return trackedFrontmostOverride() }
        return frontmostProcessIdentifier
    }
    var windowOverride: ((UInt32) -> EventStreamNativeWindow?)?
    var hit: Node?
    var parentReads = 0, windowListReads = 0
    func window(_ id: UInt32) -> EventStreamNativeWindow? {
        if let windowOverride { return windowOverride(id) }
        return windows[id]
    }
    func matchingWindows() -> [EventStreamNativeWindow] { candidates }
    func desktopWindows() -> [EventStreamNativeWindow] { desktops }
    func applicationExists(_ pid: Int32) -> Bool { apps[pid] != nil }
    func application(_ pid: Int32) -> Node { apps[pid] ?? Node("AXApplication") }
    func snapshot(_ pid: Int32, fallbackName: String?) -> EventStreamApp? {
        appRecords[pid] ?? fallbackName.map { .init(name: $0, secureInput: false, processIdentifier: pid) }
    }
    func string(_ node: Node, _ attribute: String) -> String? { node.attributes[attribute] }
    func node(_ node: Node, _ attribute: String) -> Node? {
        if attribute == "AXParent" { parentReads += 1 }
        return node.references[attribute]
    }
    func nodes(_ node: Node, _ attribute: String) -> [Node] {
        if attribute == "AXWindows" { windowListReads += 1 }
        return node.arrays[attribute] ?? []
    }
    func windowID(_ node: Node) -> UInt32? { node.windowID }
    func processIdentifier(_ node: Node) -> Int32? { node.pid }
    func frame(_ node: Node) -> CGRect? { node.bounds }
    func url(_ node: Node) -> URL? { node.url }
    func hitTest(_ point: CGPoint) -> Node? { hit }
    var content: EventStreamAXContent<Node> {
        .init(string: string, numberOfCharacters: { _ in nil }, visibleRange: { _ in nil },
              stringForRange: { _,_ in nil }, children: { Array(($0.arrays["AXChildren"] ?? []).prefix($1)) })
    }
    func directTitle(_ node: Node) -> String? { content.directTitle(node) }
    func describe(_ node: Node) -> EventStreamAXElement { content.describe(node) }
    func describeEndpoint(_ node: Node, titleOverride: String?) -> EventStreamAXElement {
        content.describeEndpoint(node, titleOverride: titleOverride)
    }
}

@main
struct EventStreamContextTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ label: String, _ result: @autoclosure () -> Bool) {
        guard result() else { fatalError("FAIL: \(label)") }
        checks += 1; print("PASS: \(label)")
    }
    static func window(_ id: UInt32, pid: Int32 = 10, title: String? = "Window", level: Int = 0, frame: CGRect = .init(x: 1, y: 2, width: 300, height: 200)) -> EventStreamNativeWindow {
        .init(id: id, processIdentifier: pid, frame: frame, level: level, title: title, ownerName: "Window Owner")
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        let backend = Backend(), app = Node("AXApplication"), first = Node("AXWindow", title: "First"), last = Node("AXWindow", title: "Last"), field = Node("AXTextField", title: "Field")
        let resolver = EventStreamContextResolver(backend: backend)
        let w20 = window(20), w21 = window(21)
        backend.windows = [20:w20,21:w21];backend.candidates=[w20,w21]
        backend.apps[10] = app;backend.appRecords[10] = .init(name: "App", secureInput: false, processIdentifier: 10, bundleIdentifier: "fixture")
        first.windowID=20;last.windowID=21;app.arrays["AXWindows"]=[first,last]
        app.references["AXFocusedUIElement"]=field
        let t20 = EventStreamEventTarget(identity:.init(processIdentifier:10,windowID:20))
        let noIDs = EventStreamEventTarget(identity:.init())
        func fails(_ expected: EventStreamCaptureContextError, _ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch { return (error as? EventStreamCaptureContextError) == expected }
        }
        let explicit = try! resolver.captureContext(.init(identity:.init(windowID:20)))
        check("capture context resolves a window without an event PID", explicit.nativeWindow.id == 20 && explicit.application === app)
        check("explicit window capture deliberately omits focused element", explicit.focusedElement == nil)
        check("capture window precedes a conflicting event PID", (try! resolver.captureContext(.init(identity:.init(processIdentifier:99,windowID:20)))).nativeWindow.processIdentifier == 10)
        check("capture uses explicit window instead of current primary", (try! resolver.captureContext(t20)).window === first)
        let primary = try! resolver.captureContext(.init(identity:.init(processIdentifier:10)))
        check("PID capture chooses last window when focused/main are absent", primary.window === last && primary.focusedElement === field)
        app.references["AXMainWindow"]=first
        check("PID capture chooses main before last window", (try! resolver.captureContext(.init(identity:.init(processIdentifier:10)))).window === first)
        app.references["AXFocusedWindow"]=last
        check("PID capture chooses focused before main", (try! resolver.captureContext(.init(identity:.init(processIdentifier:10)))).window === last)
        check("closed explicit window falls back to live requested PID", (try! resolver.captureContext(.init(identity:.init(processIdentifier:10,windowID:99)))).window === last)
        for pid in [Int32(0), -1, 999] {
            check("capture PID \(pid) falls back to tracked context", (try! resolver.captureContext(.init(identity:.init(processIdentifier:pid)))).application === app)
        }
        let otherApp=Node("AXApplication"), otherWindow=Node("AXWindow",title:"Other"), otherField=Node("AXTextField")
        otherWindow.windowID=22;backend.windows[22]=window(22,pid:11)
        otherApp.references["AXFocusedWindow"]=otherWindow;otherApp.references["AXFocusedUIElement"]=otherField
        backend.apps[11]=otherApp;backend.appRecords[11] = .init(name:"Other app",secureInput:false,processIdentifier:11)
        backend.trackedFrontmostOverride={11}
        check("capture without target uses tracked app, not raw foreground", (try! resolver.captureContext(nil)).application === otherApp)
        check("focused element without target also uses tracked app", resolver.focusedTarget(nil) === otherField)
        check("keyboard missing-window fallback retains raw foreground behavior", resolver.keyboardTarget(.init()) == .init(processIdentifier:10,windowID:21))
        var textContext=resolver.textContext(nil)
        check("text app and window fallback are resolved independently", textContext.0?.processIdentifier == 10 && textContext.1?.windowID == 22)
        let captured=EventStreamEventTarget(identity:.init(processIdentifier:99,windowID:99),app:.init(name:"Captured",secureInput:true,processIdentifier:99),window:.init(title:"Captured",url:"https://captured.test",windowID:99))
        textContext=resolver.textContext(captured)
        check("text flush preserves complete captured metadata even after focus changes", textContext.0 == captured.app && textContext.1 == captured.window)
        textContext=resolver.textContext(.init(identity:captured.identity,app:captured.app))
        check("missing captured window uses tracked foreground without changing captured app", textContext.0 == captured.app && textContext.1?.windowID == 22)
        textContext=resolver.textContext(.init(identity:captured.identity,window:captured.window))
        check("missing captured app uses raw foreground without changing captured window", textContext.0?.processIdentifier == 10 && textContext.1 == captured.window)
        otherApp.references["AXFocusedWindow"]=nil
        check("live requested app with no primary window reports failure", fails(.noPrimaryWindow) { _ = try resolver.captureContext(.init(identity:.init(processIdentifier:11))) })
        check("frontmost window failure does not discard available text app", resolver.textContext(nil).0?.processIdentifier == 10 && resolver.textContext(nil).1 == nil)
        backend.trackedFrontmostOverride={nil}
        check("missing tracked foreground fails capture despite raw foreground", fails(.noFrontmostApplication) { _ = try resolver.captureContext(nil) })
        check("strict focused-target lookup does not substitute raw foreground", resolver.focusedTarget(nil) == nil)
        backend.trackedFrontmostOverride={0}
        check("invalid tracked foreground PID fails context selection", fails(.invalidProcessIdentifier) { _ = try resolver.captureContext(nil) })
        backend.trackedFrontmostOverride=nil
        var windowReads=0
        backend.windowOverride={ id in windowReads += 1;return windowReads >= 3 ? nil : backend.windows[id] }
        check("window disappearing after explicit resolution does not fall back to another window", fails(.windowUnavailable) { _ = try resolver.captureContext(t20) })
        backend.windowOverride=nil
        app.references["AXFocusedWindow"]=first
        first.url=URL(string:"https://frontmost.test/")
        textContext=resolver.textContext(nil)
        check("text foreground URL updates shared per-window cache", textContext.1?.url == "https://frontmost.test/" && resolver.windowURLs[20] == first.url)
        first.url=nil
        check("text foreground missing URL retains previous URL", resolver.textContext(nil).1?.url == "https://frontmost.test/")
        first.attributes["AXTitle"]=""
        check("text foreground title does not borrow CG fallback title", resolver.textContext(nil).1?.title == nil)
        first.attributes["AXTitle"]="First"
        resolver.clearWindowURLs()
        check("text cache reset removes prior foreground URL", resolver.textContext(nil).1?.url == nil)
        backend.frontmostProcessIdentifier=nil
        backend.trackedFrontmostOverride={10}
        check("missing raw foreground can retain independently tracked text window", resolver.textContext(nil).0 == nil && resolver.textContext(nil).1?.windowID == 20)
        backend.frontmostProcessIdentifier=10;backend.trackedFrontmostOverride=nil
        app.references["AXMainWindow"]=nil;app.references["AXFocusedWindow"]=nil
        check("primary fallback uses last window, not first", resolver.focusedTarget(.init(identity:.init(processIdentifier:10,windowID:21))) === field)
        check("explicit mismatching window rejects focused element", resolver.focusedTarget(t20) == nil)
        app.references["AXMainWindow"]=first
        check("main window precedes last-window fallback", resolver.focusedTarget(t20) === field)
        app.references["AXFocusedWindow"]=last
        check("focused window precedes main window", resolver.focusedTarget(t20) == nil)
        check("missing target uses frontmost context", resolver.focusedTarget(nil) === field)
        check("empty target identity uses frontmost context", resolver.focusedTarget(noIDs) === field)
        check("window without PID does not borrow foreground app", resolver.focusedTarget(.init(identity:.init(windowID:21))) == nil)
        check("explicit zero PID does not borrow foreground app", resolver.focusedTarget(.init(identity:.init(processIdentifier:0))) == nil)
        check("terminated explicit PID does not borrow foreground app", resolver.focusedTarget(.init(identity:.init(processIdentifier:999))) == nil)
        backend.frontmostProcessIdentifier=nil
        check("missing foreground app yields no focus", resolver.focusedTarget(nil) == nil)
        backend.frontmostProcessIdentifier=10
        check("keyboard fallback resolves focused window with its PID", resolver.keyboardTarget(.init()) == .init(processIdentifier:10,windowID:21))
        check("explicit keyboard window survives conflicting focus", resolver.keyboardTarget(.init(processIdentifier:10,windowID:20)) == .init(processIdentifier:10,windowID:20))
        app.references["AXFocusedWindow"]=nil
        check("keyboard fallback does not substitute main window", resolver.keyboardTarget(.init(processIdentifier:10)) == .init(processIdentifier:10))
        app.references["AXFocusedWindow"]=first

        let geometric=Node("AXWindow",title:"match");geometric.bounds=w20.frame
        backend.candidates=[window(30,title:"different")]
        check("single same-frame same-PID candidate wins despite different title", resolver.matchingWindow(for:geometric,applicationPID:10)?.id == 30)
        backend.candidates=[window(30,title:"different"),window(31,title:"match")]
        check("multiple frame matches use exact title", resolver.matchingWindow(for:geometric,applicationPID:10)?.id == 31)
        backend.candidates=[window(32,title:"match"),window(31,title:"match")]
        check("remaining duplicate title matches keep original order", resolver.matchingWindow(for:geometric,applicationPID:10)?.id == 32)
        backend.candidates=[window(32,title:"Match"),window(31,title:"other")]
        check("title comparison is case sensitive", resolver.matchingWindow(for:geometric,applicationPID:10) == nil)
        backend.candidates=[window(32,pid:11,title:"match")]
        check("geometry fallback excludes another PID", resolver.matchingWindow(for:geometric,applicationPID:10) == nil)
        backend.candidates=[window(32,title:"match",frame:.init(x:1.01,y:2,width:300,height:200))]
        check("geometry fallback requires exact frame", resolver.matchingWindow(for:geometric,applicationPID:10) == nil)
        geometric.attributes["AXTitle"]=nil;backend.candidates=[w20]
        check("missing AX title rejects fallback even with one frame match", resolver.matchingWindow(for:geometric,applicationPID:10) == nil)
        geometric.windowID=20
        check("usable native ID bypasses frame and title fallback", resolver.matchingWindow(for:geometric,applicationPID:10)?.id == 20)
        let desktop=Node("AXScrollArea");backend.appRecords[10]?.bundleIdentifier="com.apple.finder"
        backend.desktops=[window(40,pid:11,level:-10),window(41,level:0),window(42,level:-10)]
        check("Finder Desktop uses first desktop-icon level window of same app", resolver.matchingWindow(for:desktop,applicationPID:10)?.id == 42)
        backend.appRecords[10]?.bundleIdentifier="fixture"
        check("Desktop special case is limited to Finder", resolver.matchingWindow(for:desktop,applicationPID:10) == nil)

        first.url=URL(string:"https://fixture.test/old");backend.candidates=[w20,w21]
        var resolved=resolver.resolve(.init(processIdentifier:10,windowID:20))
        check("event context uses AX window title and URL", resolved.window?.title == "First" && resolved.window?.url == first.url?.absoluteString && resolved.app?.name == "App")
        check("successful AX URL is cached by window ID", resolver.windowURLs[20] == first.url)
        first.url=nil
        check("missing next AX URL retains window URL cache", resolver.resolve(.init(processIdentifier:10,windowID:20)).window?.url == "https://fixture.test/old")
        first.attributes["AXTitle"]=""
        check("empty AX title falls back to CG title", resolver.resolve(.init(processIdentifier:10,windowID:20)).window?.title == "Window")
        first.attributes["AXTitle"]="   "
        check("window title whitespace is retained", resolver.resolve(.init(processIdentifier:10,windowID:20)).window?.title == "   ")
        app.arrays["AXWindows"]=[]
        check("unavailable AX matching falls back to CG metadata and cached URL", resolver.resolve(.init(processIdentifier:10,windowID:20)).window == .init(title:"Window",url:"https://fixture.test/old",windowID:20))
        resolved=resolver.resolve(.init(windowID:20))
        check("window owner does not invent missing event PID or app", resolved.identity.processIdentifier == nil && resolved.app == nil && resolved.window?.windowID == 20)
        backend.appRecords[99]=nil
        check("CG owner name supplies missing app name for explicit PID", resolver.resolve(.init(processIdentifier:99,windowID:20)).app?.name == "Window Owner")
        resolver.clearWindowURLs()
        check("explicit cache reset removes stale URL", resolver.resolve(.init(processIdentifier:10,windowID:20)).window?.url == nil)
        backend.windows[20]=nil
        resolved=resolver.resolve(.init(processIdentifier:10,windowID:20))
        check("closed window has no fabricated metadata while original identity remains", resolved.identity.windowID == 20 && resolved.window == nil && resolved.app?.processIdentifier == 10)
        backend.windows[20]=w20;app.arrays["AXWindows"]=[first,last]

        let hit=Node("AXStaticText",title:" clicked label "), row=Node("AXRow")
        hit.pid=10;hit.references["AXParent"]=row;hit.references["AXWindow"]=first
        backend.hit=hit
        var endpoint=resolver.endpoint(at:.zero,target:noIDs)
        check("static text promotes to row with trimmed clicked label", endpoint?.element?.role == "AXRow" && endpoint?.element?.title == "clicked label")
        check("missing event metadata resolves app and containing window from hit", endpoint?.app?.processIdentifier == 10 && endpoint?.window?.windowID == 20)
        let supplied=EventStreamEventTarget(identity:.init(),app:.init(name:"Supplied",secureInput:false),window:.init(title:"Supplied",windowID:77))
        endpoint=resolver.endpoint(at:.zero,target:supplied)
        check("supplied event app and window precede hit metadata", endpoint?.app?.name == "Supplied" && endpoint?.window?.windowID == 77)
        row.attributes["AXTitle"]="Raw row title"
        check("row own title precedes clicked-label override", resolver.endpoint(at:.zero,target:noIDs)?.element?.title == "Raw row title")
        let button=Node("AXButton",title:"button");hit.references["AXParent"]=button;button.references["AXParent"]=row
        check("nearest eligible parent precedes farther row", resolver.endpoint(at:.zero,target:noIDs)?.element?.role == "AXButton")
        let chain=(0...5).map{_ in Node("AXGroup")};for i in 0..<5 {chain[i].references["AXParent"]=chain[i+1]}
        let image=Node("AXImage");image.references["AXParent"]=chain[0];chain[3].attributes["AXRole"]="AXButton";backend.hit=image
        check("promotion includes parent at depth four", resolver.endpoint(at:.zero,target:noIDs)?.element?.role == "AXButton")
        chain[3].attributes["AXRole"]="AXGroup";chain[4].attributes["AXRole"]="AXButton"
        check("promotion excludes parent beyond depth four", resolver.endpoint(at:.zero,target:noIDs)?.element?.role == "AXImage")
        backend.hit=button
        check("interactive hit is retained without promotion", resolver.endpoint(at:.zero,target:noIDs)?.element?.role == "AXButton")
        backend.hit=nil
        check("unavailable system hit test returns no endpoint", resolver.endpoint(at:.zero,target:noIDs) == nil)
        let cell=Node("AXCell");cell.attributes["AXDescription"]="own description";cell.arrays["AXChildren"]=[Node("AXStaticText",title:" Child "),Node("AXStaticText",title:"Child"),Node("AXStaticText",title:"Second")]
        check("cell endpoint uses distinct descendant labels instead of own description", backend.describeEndpoint(cell,titleOverride:"row").title == "Child Second")
        let unknown=Node("AXGroup");unknown.attributes["AXDescription"]="description";unknown.arrays["AXChildren"]=[Node("AXStaticText",title:"child")]
        check("ordinary endpoint does not invent title from description or descendants", backend.describeEndpoint(unknown,titleOverride:nil).title == nil)
        unknown.attributes["AXTitle"]="  "
        check("raw nonempty endpoint title retains whitespace", backend.describeEndpoint(unknown,titleOverride:"override").title == "  ")

        let ancestry=(0...301).map{_ in Node("AXGroup")};for i in 0..<301 {ancestry[i].references["AXParent"]=ancestry[i+1]}
        ancestry[300].attributes["AXRole"]="AXWindow";ancestry[300].windowID=20;backend.parentReads=0
        check("window ancestry includes depth 300", resolver.window(of:ancestry[0])?.windowID == 20)
        check("matching window still prefetches its parent at depth 300", backend.parentReads == 301)
        ancestry[300].attributes["AXRole"]="AXGroup";ancestry[301].attributes["AXRole"]="AXWindow";ancestry[301].windowID=21
        check("window ancestry stops before depth 301", resolver.window(of:ancestry[0]) == nil)
        let cycle=Node("AXGroup");cycle.references["AXParent"]=cycle;backend.parentReads=0
        check("cyclic window ancestry is bounded by the ancestry depth cap", resolver.window(of:cycle) == nil && backend.parentReads == 301)
        let directWindow=Node("AXWindow",title:"Direct");directWindow.url=URL(string:"");cycle.references["AXWindow"]=directWindow
        check("AXWindow attribute precedes ancestry and empty endpoint URL is omitted", resolver.window(of:cycle)?.title == "Direct" && resolver.window(of:cycle)?.url == nil)
        check("window without native ID can retain AX metadata without cache key", resolver.window(of:cycle)?.windowID == nil)
        print("EVENT STREAM CONTEXT: \(checks) checks passed")
    }
}
