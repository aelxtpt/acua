import Foundation
import CoreGraphics
import CoreFoundation
final class AXUIElement: NSObject {
    var parent: AXUIElement?, role = "AXButton"
}
let kAXRoleAttribute = "AXRole", kAXParentAttribute = "AXParent"
enum AX {
    static func string(_ el: AXUIElement, _ attribute: String) -> String? { el.role }
    static func copy(_ el: AXUIElement, _ attribute: String) -> Any? { el.parent }
    static func axElement(_ value: Any?) -> AXUIElement? { value as? AXUIElement }
}
enum RequestRuntime { static func check() throws {} }
enum AppResolver {
    struct App { let running = Running() }
    struct Running { let processIdentifier: Int32 = 42 }
    static func require(_ bundle: String) throws -> App { App() }
}
enum Owned { static var hit: AXUIElement?, hitFailure = false, hitReads = 0, pointReads = 0, point: CGPoint? = CGPoint(x:10,y:20), pointThrows = false }
enum OwnedError: Error { case point }
enum Status { case success, failure }
func AXUIElementCreateApplication(_ pid: Int32) -> AXUIElement { AXUIElement() }
func AXUIElementCopyElementAtPosition(_ app: AXUIElement, _ x: Float, _ y: Float, _ hit: inout AXUIElement?) -> Status {
    Owned.hitReads += 1; hit = Owned.hit; return Owned.hitFailure ? .failure : .success
}
enum Actions {
    /* PRODUCTION_METHOD */
    static func query(_ el: AXUIElement, bundle: String = "owned.fixture") throws -> Bool {
        func point() throws -> CGPoint? { Owned.pointReads += 1; if Owned.pointThrows { throw OwnedError.point }; return Owned.point }
        return try webClickRequiresMouse(el, at: point(), bundle: bundle)
    }
}
@main struct WebTests {
    static func main() throws {
        var rows = [[String:Any]]()
        func check(_ name: String, expected: Bool, points: Int, hits: Int, bundle: String = "owned.fixture", configure: (AXUIElement)->Void = {_ in}) throws {
            let el=AXUIElement(); Owned.hit=el; Owned.hitFailure=false; Owned.hitReads=0; Owned.pointReads=0; Owned.point=CGPoint(x:10,y:20); Owned.pointThrows=false
            configure(el)
            let result=try Actions.query(el,bundle:bundle)
            let ok=result==expected && Owned.pointReads==points && Owned.hitReads==hits
            rows.append(["name":name,"passed":ok,"result":result,"pointReads":Owned.pointReads,"hitReads":Owned.hitReads]); print("\(ok ? "PASS":"FAIL") native click web \(name)")
        }
        try check("ordinary AX control skips geometry and hit test",expected:false,points:0,hits:0)
        try check("Safari prefix uses app hit test",expected:true,points:1,hits:1,bundle:"com.apple.SafariTechnologyPreview")
        try check("case-sensitive Safari prefix",expected:false,points:0,hits:0,bundle:"COM.APPLE.Safari")
        try check("web self requires mouse on matching hit",expected:true,points:1,hits:1) { $0.role="AXWebArea" }
        try check("web parent and descendant hit",expected:true,points:1,hits:1) { el in let web=AXUIElement();web.role="AXWebArea";el.parent=web;let hit=AXUIElement();hit.parent=el;Owned.hit=hit }
        try check("unrelated hit keeps AX delivery",expected:false,points:1,hits:1) { $0.role="AXWebArea";Owned.hit=AXUIElement() }
        try check("missing point keeps AX delivery",expected:false,points:1,hits:0) { $0.role="AXWebArea";Owned.point=nil }
        try check("point error is swallowed before hit test",expected:false,points:1,hits:0) { $0.role="AXWebArea";Owned.pointThrows=true }
        try check("failed hit test keeps AX delivery",expected:false,points:1,hits:1) { $0.role="AXWebArea";Owned.hitFailure=true }
        try check("absent hit keeps AX delivery",expected:false,points:1,hits:1) { $0.role="AXWebArea";Owned.hit=nil }
        try check("depth 300 is included",expected:true,points:1,hits:1) { el in var node=el;for _ in 0..<300 {let parent=AXUIElement();node.parent=parent;node=parent};node.role="AXWebArea" }
        try check("depth 301 is excluded",expected:false,points:0,hits:0) { el in var node=el;for _ in 0..<301 {let parent=AXUIElement();node.parent=parent;node=parent};node.role="AXWebArea" }
        let passed=rows.filter { $0["passed"] as? Bool==true }.count
        try JSONSerialization.data(withJSONObject:["passed":passed,"failed":rows.count-passed,"checks":rows],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if passed != rows.count {exit(1)}
    }
}
