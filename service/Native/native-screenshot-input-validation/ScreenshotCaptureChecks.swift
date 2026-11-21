import Foundation
import CoreGraphics

private enum CaptureCheckFailure: Error { case sleep, content, capture }
private struct CheckWindow: Sendable {
    let id: UInt32
    var frame: CGRect = .init(x: 10, y: 20, width: 100, height: 80)
    var onScreen = true
    var name: String? = "Owned App"
    var title: String? = "Owned title"
}
private struct CheckDisplay: Sendable {
    let id: Int
    var frame: CGRect = .init(x: 0, y: 0, width: 800, height: 600)
    var pixels: CGSize = .init(width: 800, height: 600)
}
private struct CheckFilter: Sendable { let kind: String; let ids: [UInt32]; let display: Int? }
private final class CheckConfiguration: @unchecked Sendable {}
private struct CheckImage: Sendable, Equatable { let token: String }

private final class CaptureCheckWorld: ControllerScreenshotCaptureBackend, @unchecked Sendable {
    typealias Content = Int
    typealias Window = CheckWindow
    typealias Display = CheckDisplay
    typealias Filter = CheckFilter
    typealias Configuration = CheckConfiguration
    typealias Image = CheckImage
    struct State {
        var trace: [String] = []
        var own: [UInt32] = []
        var visible: [UInt32] = [1, 2, 3]
        var supportsCurrentProcess = true
        var windowLists = [[CheckWindow(id: 1)]]
        var displayLists = [[CheckDisplay(id: 1)]]
        var windowRead = 0, displayRead = 0
        var scope: ControllerScreenshotContentScope?
        var filter: CheckFilter?
        var size: [Int]?
        var source: CGRect?
        var scale: CGFloat = 1
        var skyLightIDs: [UInt32]?
        var skyLightFrame: CGRect?
        var resizeSize: CGSize?
        var resizeResult: CheckImage?
        var skyLightResult: CheckImage? = .init(token: "skyLight")
        var failSleep = false, failContent = false, failCapture = false
        var pauseContent = false, pauseSleep = false, cancellableSleep = false
        var contentGate: CheckedContinuation<Void,Never>?
        var sleepGate: CheckedContinuation<Void,Never>?
    }
    private let lock = NSLock()
    private var storage = State()
    @discardableResult func state<T>(_ work: (inout State) -> T) -> T { lock.withLock { work(&storage) } }
    var snapshot: State { state { $0 } }
    func releaseContent() { let gate=state { s in let value=s.contentGate;s.contentGate=nil;return value };gate?.resume() }
    func releaseSleep() { let gate=state { s in let value=s.sleepGate;s.sleepGate=nil;return value };gate?.resume() }
    var currentProcessContentAvailable: Bool { state { $0.trace.append("availability"); return $0.supportsCurrentProcess } }
    @MainActor func ownVisibleWindowIDs() -> [UInt32] { state { $0.trace.append("own"); return $0.own } }
    func onScreenWindowIDs() -> [UInt32] { state { $0.trace.append("onscreen"); return $0.visible } }
    func sleep(seconds: Int) async throws {
        let failed = state { $0.trace.append("sleep:\(seconds)"); return $0.failSleep }
        if failed { throw CaptureCheckFailure.sleep }
        if state({$0.pauseSleep}) { await withCheckedContinuation { continuation in state {$0.sleepGate=continuation} } }
        if state({$0.cancellableSleep}) { try Task.checkCancellation() }
    }
    func content(_ scope: ControllerScreenshotContentScope) async throws -> Int {
        let failed = state { $0.trace.append("content"); $0.scope = scope; return $0.failContent }
        if state({$0.pauseContent}) { await withCheckedContinuation { continuation in state {$0.contentGate=continuation} } }
        if failed { throw CaptureCheckFailure.content }
        return 1
    }
    func windows(_ content: Int) -> [CheckWindow] {
        state { s in s.trace.append("windows"); defer { s.windowRead += 1 }; return s.windowLists[min(s.windowRead,s.windowLists.count-1)] }
    }
    func displays(_ content: Int) -> [CheckDisplay] {
        state { s in s.trace.append("displays"); defer { s.displayRead += 1 }; return s.displayLists[min(s.displayRead,s.displayLists.count-1)] }
    }
    func id(_ window: CheckWindow) -> UInt32 { state { $0.trace.append("id:\(window.id)") }; return window.id }
    func isOnScreen(_ window: CheckWindow) -> Bool { state { $0.trace.append("visible:\(window.id)") }; return window.onScreen }
    func frame(_ window: CheckWindow) -> CGRect { state { $0.trace.append("frame:\(window.id)") }; return window.frame }
    func applicationName(_ window: CheckWindow) -> String? { state { $0.trace.append("name:\(window.id)") }; return window.name }
    func title(_ window: CheckWindow) -> String? { state { $0.trace.append("title:\(window.id)") }; return window.title }
    func frame(_ display: CheckDisplay) -> CGRect { state { $0.trace.append("displayFrame:\(display.id)") }; return display.frame }
    func pixelSize(_ display: CheckDisplay) -> CGSize { state { $0.trace.append("displayPixels:\(display.id)") }; return display.pixels }
    private func record(_ filter: CheckFilter) -> CheckFilter { state { $0.trace.append("filter:\(filter.kind)"); $0.filter = filter }; return filter }
    func filter(window: CheckWindow) -> CheckFilter { record(.init(kind:"window",ids:[window.id],display:nil)) }
    func filter(display: CheckDisplay, including windows: [CheckWindow]) -> CheckFilter { record(.init(kind:"including",ids:windows.map(\.id),display:display.id)) }
    func filter(display: CheckDisplay, excluding windows: [CheckWindow]) -> CheckFilter { record(.init(kind:"excluding",ids:windows.map(\.id),display:display.id)) }
    func pointPixelScale(_ filter: CheckFilter) -> CGFloat { state { $0.trace.append("scale"); return $0.scale } }
    func configuration(opaque: Bool, includeWindowShadow: Bool) -> CheckConfiguration {
        state { $0.trace.append("configuration:\(opaque):\(includeWindowShadow)") }; return .init()
    }
    func setSize(_ configuration: CheckConfiguration, width: Int, height: Int) { state { $0.trace.append("size"); $0.size=[width,height] } }
    func setSourceRect(_ configuration: CheckConfiguration, _ rect: CGRect) { state { $0.trace.append("source"); $0.source=rect } }
    func capture(_ filter: CheckFilter, configuration: CheckConfiguration) async throws -> CheckImage {
        let failed = state { $0.trace.append("capture"); return $0.failCapture }
        if failed { throw CaptureCheckFailure.capture }
        return .init(token:"screen")
    }
    func captureWithSkyLight(windowIDs: [UInt32], rect: CGRect) -> CheckImage? {
        state { $0.trace.append("skyLight"); $0.skyLightIDs=windowIDs; $0.skyLightFrame=rect; return $0.skyLightResult }
    }
    func resize(_ image: CheckImage, to size: CGSize) -> CheckImage? { state { $0.trace.append("resize"); $0.resizeSize=size; return $0.resizeResult } }
    func invalidSize(_ size: CGSize) { state { $0.trace.append("invalidSize") } }
}

enum ScreenshotCaptureChecks {
    static func run(output: URL) async throws -> Int32 {
        var checks: [[String:Any]]=[]
        func check(_ name: String, _ passed: Bool) { checks.append(["name":name,"passed":passed]); if !passed { print("FAIL: "+name) } }
        let scopes: [([UInt32]?,[UInt32],[UInt32],Bool,ControllerScreenshotContentScope,[String])] = [
            (nil,[],[],true,.onScreenExcludingDesktop,[]),
            ([],[],[],true,.currentProcess,["own","availability"]),
            ([2,2],[2],[],true,.currentProcess,["own","availability"]),
            ([2],[2],[],false,.all,["own","availability"]),
            ([2],[],[2],true,.onScreenExcludingDesktop,["own","onscreen"]),
            ([2,3],[2],[2,3],true,.onScreenExcludingDesktop,["own","onscreen"]),
            ([2,3],[2],[2],true,.all,["own","onscreen"]),
            ([0],[],[],true,.all,["own","onscreen"])]
        for (i,row) in scopes.enumerated() {
            let w=CaptureCheckWorld();w.state { $0.own=row.1;$0.visible=row.2;$0.supportsCurrentProcess=row.3 }
            let result=await ControllerScreenshotCapture(backend:w).contentScope(includedIDs:row.0)
            check("content scope and lazy provider order \(i)",result==row.4 && w.snapshot.trace==row.5)
        }
        for delay: Int? in [nil,0,-1,4] {
            let w=CaptureCheckWorld();_ = try await ControllerScreenshotCapture(backend:w).capture(.init(delaySeconds:delay,imageSize:.init(width:10,height:10),includedWindowIDs:[1]))
            check("optional positive delay uses seconds \(String(describing:delay))",w.snapshot.trace.first==(delay==4 ? "sleep:4":"own"))
        }
        for stage in ["sleep","content","capture"] {
            let w=CaptureCheckWorld();w.state { $0.failSleep=stage=="sleep";$0.failContent=stage=="content";$0.failCapture=stage=="capture" }
            var caught=false
            do { _ = try await ControllerScreenshotCapture(backend:w).capture(.init(delaySeconds:1,includedWindowIDs:[1])) }
            catch CaptureCheckFailure.sleep { caught=stage=="sleep" }
            catch CaptureCheckFailure.content { caught=stage=="content" }
            catch CaptureCheckFailure.capture { caught=stage=="capture" }
            check("native provider failure propagates without retry \(stage)",caught && w.snapshot.trace.filter { $0==stage }.count <= 1)
            if stage=="sleep" { check("sleep failure precedes any window/content read",w.snapshot.trace==["sleep:1"]) }
            if stage=="content" { check("content failure does not inspect windows or make a filter",!w.snapshot.trace.contains("windows") && w.snapshot.filter==nil) }
        }
        do {
            let w=CaptureCheckWorld();w.state { $0.scale=2 }
            _ = try await ControllerScreenshotCapture(backend:w).capture(.init())
            check("nil IDs select the first display with an empty excluding filter",w.snapshot.filter?.kind=="excluding" && w.snapshot.filter?.display==1 && w.snapshot.filter?.ids==[])
            check("display dimensions use pixel getters before applying filter scale",w.snapshot.size==[1600,1200] && w.snapshot.source==nil)
            check("configuration precedes the natural-size scale getter",w.snapshot.trace.firstIndex(of:"configuration:true:false")! < w.snapshot.trace.firstIndex(of:"scale")!)
        }
        do {
            let w=CaptureCheckWorld();_ = try await ControllerScreenshotCapture(backend:w).capture(.init(imageSize:.init(width:11.1,height:12.2),includedWindowIDs:[1],shouldBeOpaque:false,includeWindowShadow:true))
            check("single ID uses its actual desktop-independent window",w.snapshot.filter?.kind=="window" && w.snapshot.filter?.ids==[1] && w.snapshot.windowRead==2)
            check("explicit image size rounds upward without reading filter scale",w.snapshot.size==[12,13] && !w.snapshot.trace.contains("scale"))
            check("opaque and shadow options reach configuration unchanged",w.snapshot.trace.contains("configuration:false:true"))
            check("desktop-independent capture does not ask for displays or source rect",w.snapshot.displayRead==0 && w.snapshot.source==nil)
            check("single-window natural size reads frame separately for width and height",w.snapshot.trace.filter { $0=="frame:1" }.count==2)
        }
        do {
            let w=CaptureCheckWorld();w.state { $0.windowLists=[[.init(id:0)]] }
            _ = try await ControllerScreenshotCapture(backend:w).capture(.init(includedWindowIDs:[0]))
            check("present raw zero window ID is not replaced or rejected",w.snapshot.filter?.ids==[0])
        }
        let matching: [(String,[CheckWindow],UInt32?)] = [
            ("  OWNED APP \n",[.init(id:1,name:"Other"),.init(id:2,name:"Owned App")],2),
            ("Owned",[.init(id:1,name:"Owned Extra"),.init(id:2,name:"Owned")],2),
            ("Own",[.init(id:1,name:"Owned Extra")],1),
            ("wn",[.init(id:1,name:"Owned")],nil),
            ("wned",[.init(id:1,name:"Owned App")],1),
            ("",[.init(id:1,name:" "),.init(id:2,name:nil),.init(id:3,name:"Valid")],3),
            ("Owned",[.init(id:1,onScreen:false,name:"Owned"),.init(id:2,name:"Owned Extra")],2),
            ("🙂🙂🙂",[.init(id:1,name:"before🙂🙂🙂after")],nil),
            ("🙂🙂🙂🙂",[.init(id:1,name:"before🙂🙂🙂🙂after")],1)]
        for (i,row) in matching.enumerated() {
            let w=CaptureCheckWorld();w.state { $0.windowLists=[row.1] }
            _ = try await ControllerScreenshotCapture(backend:w).capture(.init(appName:row.0,imageSize:.init(width:10,height:10)))
            check("ordered app-name matching \(i)",row.2.map { w.snapshot.filter?.kind=="window" && w.snapshot.filter?.ids==[$0] } ?? (w.snapshot.filter?.kind=="excluding"))
        }
        do {
            let w=CaptureCheckWorld();w.state { $0.windowLists=[[.init(id:1,name:"Owned")],[],[]] }
            _ = try await ControllerScreenshotCapture(backend:w).capture(.init(appName:"Owned",imageSize:.init(width:10,height:10)))
            check("selected app-name ID is looked up again before dictionary capture",w.snapshot.windowRead==3 && w.snapshot.filter?.kind=="excluding")
        }
        do {
            let w=CaptureCheckWorld();w.state { $0.windowLists=[[.init(id:2,frame:.init(x:900,y:30,width:100,height:80))]];$0.displayLists=[[.init(id:1),.init(id:2,frame:.init(x:800,y:0,width:800,height:600))]] }
            _ = try await ControllerScreenshotCapture(backend:w).capture(.init(includedWindowIDs:[77,2,2],cropToFirstWindow:true))
            check("multi-window selection compacts absent IDs and preserves duplicates",w.snapshot.filter?.ids==[2,2])
            check("missing first crop ID falls back to the included frame union",w.snapshot.source == .init(x:100,y:30,width:100,height:80))
            check("multi-window display uses maximum intersection",w.snapshot.filter?.display==2 && w.snapshot.size==[100,80])
            check("display getters are reread and source rect follows size setters",w.snapshot.displayRead==2 && w.snapshot.trace.firstIndex(of:"size")! < w.snapshot.trace.firstIndex(of:"source")!)
        }
        do {
            let primary = CheckDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            let upper = CheckDisplay(id: 2, frame: CGRect(x: 0, y: -600, width: 800, height: 600))
            let frame = CGRect(x: 30, y: -40, width: 120, height: 80)
            for (displays, expectedDisplay, sourceY) in [
                ([primary, upper], 1, -40.0), ([upper, primary], 2, 560.0)
            ] {
                let world = CaptureCheckWorld()
                world.state {
                    $0.windowLists = [[.init(id: 1, frame: frame)]]
                    $0.displayLists = [displays]
                }
                _ = try await ControllerScreenshotCapture(backend: world).capture(
                    .init(includedWindowIDs: [1, 77], cropToFirstWindow: true))
                check("equal positive overlap keeps first display \(expectedDisplay)",
                      world.snapshot.filter?.display == expectedDisplay &&
                      world.snapshot.source == CGRect(x: 30, y: sourceY, width: 120, height: 80))
            }
        }
        do {
            let w=CaptureCheckWorld();w.state { $0.windowLists=[[.init(id:1),.init(id:2,frame:.init(x:200,y:20,width:50,height:80))]] }
            _ = try await ControllerScreenshotCapture(backend:w).capture(.init(includedWindowIDs:[1,2],cropToFirstWindow:false))
            check("uncropped included windows use their frame union",w.snapshot.source == .init(x:10,y:20,width:240,height:80))
        }
        for crop in [false,true] {
            let w=CaptureCheckWorld();w.state { $0.windowLists=[[.init(id:1,onScreen:false),.init(id:2)]] }
            _ = try await ControllerScreenshotCapture(backend:w).capture(.init(includedWindowIDs:[1,2,2,77],cropToFirstWindow:crop))
            check("offscreen first multi-ID window uses SkyLight only when cropped \(crop)",crop ? w.snapshot.skyLightIDs==[1,2,2,77] && w.snapshot.filter==nil : w.snapshot.skyLightIDs==nil && w.snapshot.filter?.kind=="including")
        }
        for resize in [false,true] {
            let w=CaptureCheckWorld();w.state { $0.windowLists=[[.init(id:1,onScreen:false)]];if resize {$0.resizeResult = .init(token:"resized")} }
            let result=try await ControllerScreenshotCapture(backend:w).capture(.init(imageSize:.init(width:10.9,height:11.8),includedWindowIDs:[1]))
            check("offscreen raw fallback or resized result \(resize)",result.token==(resize ? "resized":"skyLight") && w.snapshot.resizeSize == .init(width:10.9,height:11.8))
            check("offscreen capture bypasses stream configuration \(resize)",w.snapshot.skyLightIDs==[1] && w.snapshot.filter==nil && w.snapshot.size==nil)
        }
        do {
            let w=CaptureCheckWorld();w.state { $0.windowLists=[[.init(id:1,onScreen:false)]];$0.skyLightResult=nil }
            var failed=false;do {_ = try await ControllerScreenshotCapture(backend:w).capture(.init(includedWindowIDs:[1]))}
            catch ControllerScreenshotCaptureError.screenCaptureFailed {failed=true}
            check("nil accelerated capture reports screenCaptureFailed",failed && !w.snapshot.trace.contains("resize"))
        }
        do {
            let w=CaptureCheckWorld();w.state {$0.displayLists=[[]]}
            var failed=false;do {_ = try await ControllerScreenshotCapture(backend:w).capture(.init())}
            catch ControllerScreenshotCaptureError.screenCaptureFailed {failed=true}
            check("no display fails before filter and configuration creation",failed && w.snapshot.filter==nil && w.snapshot.size==nil)
        }
        do {
            let w=CaptureCheckWorld();w.state {$0.displayLists=[[]]}
            _ = try await ControllerScreenshotCapture(backend:w).capture(.init(includedWindowIDs:[1]))
            check("selected window capture needs no display metadata",w.snapshot.displayRead==0 && w.snapshot.filter?.kind=="window")
        }
        do {
            let w=CaptureCheckWorld();w.state {$0.displayLists=[[.init(id:9)],[]]}
            _ = try await ControllerScreenshotCapture(backend:w).capture(.init(includedWindowIDs:[1,77],cropToFirstWindow:true))
            check("empty second display read retains the first-read fallback",w.snapshot.filter?.display==9)
        }
        do {
            let w=CaptureCheckWorld();w.state {$0.windowLists=[[]]}
            _ = try await ControllerScreenshotCapture(backend:w).capture(.init(imageSize:.init(width:10,height:10),includedWindowIDs:[77]))
            check("missing explicit ID does not invent a different window or guard",w.snapshot.filter?.kind=="including" && w.snapshot.filter?.ids==[] && w.snapshot.source?.isNull==true)
        }
        do {
            let w=CaptureCheckWorld();var failed=false
            do {_ = try await ControllerScreenshotCapture(backend:w).capture(.init(includedWindowIDs:[]))}
            catch ControllerScreenshotCaptureError.invalidCaptureSize(let size) {failed=size == .zero}
            check("empty present IDs retain the null union and the invalid size error",failed && w.snapshot.filter?.kind=="including")
            check("invalid dimensions create configuration but do not set width or capture",w.snapshot.trace.contains("configuration:true:false") && w.snapshot.trace.last=="invalidSize" && w.snapshot.size==nil)
        }
        let sizes:[(CGFloat,CGFloat,[Int]?)] = [(1.1,2.9,[2,3]),(.leastNonzeroMagnitude,.leastNonzeroMagnitude,[1,1]),(0,1,nil),(-0.0,1,nil),(-1,2,nil),(1,0,nil),(1,-1,nil),(.nan,1,nil),(1,.nan,nil),(.infinity,1,nil),(1,.infinity,nil),(-.infinity,1,nil),(1,-.infinity,nil),(.greatestFiniteMagnitude,1,nil),(1,.greatestFiniteMagnitude,nil),(CGFloat(Int.max).nextDown,1,[Int(CGFloat(Int.max).nextDown),1])]
        for (i,row) in sizes.enumerated() {
            let size = ScreenshotGeometry.pixelSize(.init(width: row.0, height: row.1), offscreen: false)
            check("native stream dimension validation and rounding \(i)",size.map {[$0.width,$0.height]}==row.2)
        }
        for size in [CGSize(width: CGFloat(Int.max), height: 1), CGSize(width: 1, height: CGFloat(Int.max))] {
            let world = CaptureCheckWorld()
            var rejected = false
            do {
                _ = try await ControllerScreenshotCapture(backend: world).capture(
                    .init(imageSize: size, includedWindowIDs: [1]))
            } catch ControllerScreenshotCaptureError.invalidCaptureSize(let rejectedSize) {
                rejected = rejectedSize == size
            }
            check("size outside Int range returns a capture error \(size)",
                  rejected && world.snapshot.trace.last == "invalidSize" && world.snapshot.size == nil)
        }
        for onscreen in [true, false] {
            let world = CaptureCheckWorld()
            world.state { $0.windowLists = [[.init(id: 1, onScreen: onscreen), .init(id: 1)]] }
            var rejected = false
            do {
                _ = try await ControllerScreenshotCapture(backend: world).capture(.init(includedWindowIDs: [1]))
            } catch ControllerScreenshotCaptureError.screenCaptureFailed {
                rejected = true
            }
            check("duplicate metadata rejects ambiguous window before capture, onscreen=\(onscreen)",
                  rejected && world.snapshot.filter == nil && world.snapshot.skyLightIDs == nil)
        }
        do {
            let w=CaptureCheckWorld();w.state {$0.pauseContent=true}
            let task=Task { try await ControllerScreenshotCapture(backend:w).capture(.init(includedWindowIDs:[1])) }
            while w.snapshot.contentGate==nil { await Task.yield() }
            task.cancel();w.releaseContent()
            let result=try await task.value
            check("cancelled caller adds no checkpoint around a noncancellable content provider",result.token=="screen" && w.snapshot.trace.last=="capture")
        }
        do {
            let w=CaptureCheckWorld();w.state {$0.pauseSleep=true;$0.cancellableSleep=true}
            let task=Task { try await ControllerScreenshotCapture(backend:w).capture(.init(delaySeconds:1,includedWindowIDs:[1])) }
            while w.snapshot.sleepGate==nil { await Task.yield() }
            task.cancel();w.releaseSleep()
            var cancelled=false;do {_ = try await task.value} catch is CancellationError {cancelled=true}
            check("positive delay propagates its sleep-provider cancellation",cancelled)
            check("sleep cancellation prevents content and metadata reads",w.snapshot.trace==["sleep:1"])
        }
        do {
            let w=CaptureCheckWorld();w.state {$0.pauseContent=true;$0.failContent=true}
            let task=Task { try await ControllerScreenshotCapture(backend:w).capture(.init(includedWindowIDs:[1])) }
            while w.snapshot.contentGate==nil { await Task.yield() }
            task.cancel();w.releaseContent()
            var caught=false;do {_ = try await task.value} catch CaptureCheckFailure.content {caught=true}
            check("actual content-provider failure wins over an unobserved cancellation",caught && w.snapshot.filter==nil)
        }
        let passed=checks.allSatisfy {$0["passed"] as? Bool==true}
        try JSONSerialization.data(withJSONObject:["passed":passed,"checks":checks,
            "native_capture_effects_injected":true,"actual_screen_capture_input_focus_or_preferences":false,
            "full_goal_complete":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Screenshot capture core: \(checks.filter {$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
}
