import Foundation
import CoreFoundation

enum AXError: Int { case success = 0, cannotComplete = -25204, attributeUnsupported = -25205, failure = -25200 }
final class AXUIElement {
    let id: Int
    var role: String? = "AXButton", subrole: String?, parent: AXUIElement?
    var children = [AXUIElement](), visibleRows = [AXUIElement](), visibleChildren = [AXUIElement]()
    var actions = [String](), supported: Set<String> = ["AXRole","AXSubrole","AXChildren","AXDisclosing"]
    var disclosable = true, disclosing: AnyObject? = NSNumber(value:false)
    var vertical: AXUIElement?, horizontal: AXUIElement?
    var actionStatus = AXError.success, setterStatus = AXError.success
    var namesStatus = AXError.success, countStatus = AXError.success
    var countOverrides = [String:Int]()
    init(_ id: Int, role: String? = "AXButton", subrole: String? = nil) { self.id=id;self.role=role;self.subrole=subrole }
}
struct AXReference: Hashable { let element: AXUIElement; static func ==(a:Self,b:Self)->Bool {a.element === b.element};func hash(into h:inout Hasher){h.combine(ObjectIdentifier(element))} }
enum Owned {
    static var trace = [String](), writes = [Bool](), attributes = [String](), routes = [Int]()
    static var checkpoints=0, cancelAt: Int?
    static var failRoutingID: Int?
    static func reset(){trace=[];writes=[];attributes=[];routes=[];checkpoints=0;cancelAt=nil;failRoutingID=nil}
}
enum RequestRuntime {
    static func check() throws {
        Owned.checkpoints += 1
        if Owned.checkpoints == Owned.cancelAt { throw ServiceError(.unknownError,"owned cancellation") }
    }
}
enum AX {
    static func onElement<T>(_ el: AXUIElement,_ body:()throws->T) throws->T {
        Owned.routes.append(el.id)
        if Owned.failRoutingID == el.id {throw ServiceError(.unknownError,"owned routing failure")}
        return try body()
    }
    static func copy(_ el: AXUIElement,_ attribute:String)->AnyObject? {
        switch attribute {
        case "AXRole": return el.role as AnyObject?
        case "AXSubrole":return el.subrole as AnyObject?
        case "AXParent":return el.parent
        case "AXChildren":return el.children as AnyObject
        case "AXVisibleRows":return el.visibleRows as AnyObject
        case "AXVisibleChildren":return el.visibleChildren as AnyObject
        case "AXDisclosing":return el.disclosing
        case "AXVerticalScrollBar":return el.vertical
        case "AXHorizontalScrollBar":return el.horizontal
        default:return nil
        }
    }
    static func string(_ el:AXUIElement,_ attribute:String)->String? {copy(el,attribute) as? String}
    static func axElement(_ value:AnyObject?)->AXUIElement? {value as? AXUIElement}
    static func children(_ el:AXUIElement)->[AXUIElement] {el.children}
    static func actionNames(_ el:AXUIElement)->[String] {el.actions}
}
func AXUIElementCopyAttributeNames(_ el:AXUIElement,_ output:inout CFArray?)->AXError {output=Array(el.supported) as CFArray;return el.namesStatus}
func AXUIElementGetAttributeValueCount(_ el:AXUIElement,_ name:CFString,_ output:inout CFIndex)->AXError {
    let key=name as String
    output=el.countOverrides[key] ?? ((AX.copy(el,key) as? [AnyObject])?.count ?? 0)
    return el.countStatus
}
func AXUIElementIsAttributeSettable(_ el:AXUIElement,_ name:CFString,_ output:inout DarwinBoolean)->AXError {
    Owned.trace.append("capability");output=DarwinBoolean(el.disclosable);return .success
}
func AXUIElementSetAttributeValue(_ el:AXUIElement,_ name:CFString,_ value:CFTypeRef)->AXError {
    Owned.trace.append("set");Owned.writes.append((value as? Bool) ?? false);Owned.attributes.append(name as String)
    if el.setterStatus == .success {el.disclosing=value}
    return el.setterStatus
}
func AXUIElementPerformAction(_ el:AXUIElement,_ name:CFString)->AXError {Owned.trace.append("ax:\(el.id):\(name)");return el.actionStatus}

struct OwnedBackend:NativeElementActionBackend {
    func identity(_ el:AXUIElement)->Int {el.id}
    func role(_ el:AXUIElement)throws->String? {el.role}
    func subrole(_ el:AXUIElement)throws->String? {el.subrole}
    func parent(_ el:AXUIElement)throws->AXUIElement? {el.parent}
    func children(_ el:AXUIElement)throws->[AXUIElement] {el.children}
    func childrenPreferringVisible(_ el:AXUIElement)throws->[AXUIElement] {!el.visibleRows.isEmpty ? el.visibleRows : (!el.visibleChildren.isEmpty ? el.visibleChildren:el.children)}
    func actions(_ el:AXUIElement)throws->[String] {el.actions}
    func canDisclose(_ el:AXUIElement)throws->Bool {Owned.trace.append("capability");return el.disclosable}
    func isDisclosing(_ el:AXUIElement)throws->Bool {Owned.trace.append("value");return (el.disclosing as? Bool) ?? false}
    func setDisclosing(_ value:Bool,for el:AXUIElement)throws {
        Owned.trace.append("set");Owned.writes.append(value);Owned.attributes.append("AXDisclosing")
        if el.setterStatus != .success {throw ServiceError(.accessibilityError,"owned setter")}
        el.disclosing=NSNumber(value:value)
    }
    func scrollBar(_ el:AXUIElement,vertical:Bool)throws->AXUIElement? {vertical ? el.vertical:el.horizontal}
    func performAX(_ action:String,on el:AXUIElement)throws {
        Owned.trace.append("ax:\(el.id):\(action)")
        if ![AXError.success,.cannotComplete,.attributeUnsupported].contains(el.actionStatus) {throw ServiceError(.accessibilityError,"owned AX failure")}
    }
    func checkpoint()throws {try RequestRuntime.check()}
}

@main struct NativeActionTests {
    struct Expected:Decodable {
        struct Direction:Decodable {let action:String;let direction:UInt8}
        struct Disclosure:Decodable {let name:String;let capability:Bool;let value:Bool;let failSetter:Bool;let trace:[String];let writes:[Bool];let attributes:[String];let failed:Bool}
        let directions:[Direction];let disclosure:[Disclosure]
    }
    static func main()throws {
        var rows=[[String:Any]]()
        func check(_ ok:Bool,_ name:String){rows.append(["name":name,"passed":ok]);print("\(ok ? "PASS":"FAIL") native element action \(name)")}
        func run(_ el:AXUIElement,_ action:String,native:Bool=false)->Bool {
            do {if native {try AXNativeElementActions.perform(el,action:action)}else{try NativeElementAction.perform(el,action:action,backend:OwnedBackend())};return true}catch{return false}
        }
        let expected=try JSONDecoder().decode(Expected.self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))
        for row in expected.directions {check((NativeScrollActionDirection(action:row.action)?.rawValue ?? 4)==row.direction,"scroll direction \(row.action)")}
        for action in ["SAIExpand","SAICollapse"] {
            for row in expected.disclosure {
                Owned.reset();let el=AXUIElement(1);el.disclosable=row.capability;el.disclosing=NSNumber(value:row.value);el.setterStatus=row.failSetter ? .failure:.success
                let result=run(el,action)
                check(result == !row.failed && Owned.trace == row.trace && Owned.writes == row.writes && Owned.attributes == row.attributes,"disclosure \(action) \(row.name)")
            }
        }
        for direction in [NativeScrollActionDirection.up,.down,.left,.right] {
            Owned.reset();let el=AXUIElement(1),bar=AXUIElement(2,role:"AXScrollBar"),wrong=AXUIElement(3,role:"AXGroup",subrole:direction.pageButtonSubrole)
            let first=AXUIElement(4,subrole:direction.pageButtonSubrole),second=AXUIElement(5,subrole:direction.pageButtonSubrole)
            bar.children=[wrong,first,second];if direction.vertical{el.vertical=bar}else{el.horizontal=bar}
            let name=["AXScrollUpByPage","AXScrollDownByPage","AXScrollLeftByPage","AXScrollRightByPage"][Int(direction.rawValue)]
            check(run(el,name) && Owned.trace == ["ax:4:AXPress"],"\(name) presses first matching page button")
            Owned.reset();first.actionStatus = .failure
            check(!run(el,name) && Owned.trace == ["ax:4:AXPress"],"\(name) page press failure cannot retry raw action")
            Owned.reset();bar.children=[wrong]
            check(run(el,name) && Owned.trace == ["ax:1:\(name)"],"\(name) missing page button uses raw action")
            Owned.reset();el.vertical=nil;el.horizontal=nil
            check(run(el,name) && Owned.trace == ["ax:1:\(name)"],"\(name) missing bar uses raw action")
        }
        Owned.reset();let item=AXUIElement(1,role:"AXMenuItem"),near=AXUIElement(2,role:"AXMenu"),far=AXUIElement(3,role:"AXMenu")
        item.parent=near;near.parent=far;near.actions=["AXPress"];far.actions=["AXPress"]
        check(run(item,"AXPress") && Owned.trace == ["ax:2:AXPress","ax:1:AXPress"],"menu forwards to nearest eligible empty ancestor before self")
        Owned.reset();near.actionStatus = .failure
        check(!run(item,"AXPress") && Owned.trace == ["ax:2:AXPress"],"ancestor failure stops the menu item press")
        Owned.reset();near.actionStatus = .success;near.children=[AXUIElement(7)]
        check(run(item,"AXPress") && Owned.trace == ["ax:1:AXPress"],"populated ancestor stops forwarding before checking actions")
        Owned.reset();near.children=[];near.actions=[]
        check(run(item,"AXPress") && Owned.trace == ["ax:3:AXPress","ax:1:AXPress"],"menu searches farther empty ancestor when nearest lacks action")
        Owned.reset();near.actions=["AXPress"];item.parent=item;item.actions=["AXPress"]
        check(!run(item,"AXPress") && !Owned.trace.contains(where:{$0.hasPrefix("ax:")}),"cyclic menu dependency fails before delivery")
        Owned.reset();let root=AXUIElement(0,role:"AXMenuItem");var previous=root
        for id in 1...301 {let next=AXUIElement(id,role:"AXMenu");if id==301{next.actions=["AXPress"]};previous.parent=next;previous=next}
        check(run(root,"AXPress") && Owned.trace == ["ax:0:AXPress"],"menu traversal excludes ancestor depth 301")
        Owned.reset();let plain=AXUIElement(10);Owned.cancelAt=1
        check(!run(plain,"SAIExpand") && Owned.trace.isEmpty && Owned.writes.isEmpty,"cancellation precedes capability and effects")

        // The entire concrete production AX adapter below runs against these
        // owned C API providers, without constructing real AX/UI objects.
        for value in [false,true] {
            for action in ["SAIExpand","SAICollapse"] {
                Owned.reset();let el=AXUIElement(1);el.disclosing=NSNumber(value:value)
                check(run(el,action,native:true) && Owned.writes == [!value] && Owned.attributes == ["AXDisclosing"] && !Owned.trace.contains(where:{$0.hasPrefix("ax:")}) && !Owned.routes.isEmpty,"native adapter toggles \(action) from \(value)")
            }
        }
        for status in [AXError.cannotComplete,.attributeUnsupported,.failure] {
            Owned.reset();let el=AXUIElement(1);el.setterStatus=status
            check(!run(el,"SAIExpand",native:true) && Owned.writes == [true],"native setter status \(status.rawValue) propagates")
        }
        for status in [AXError.success,.cannotComplete,.attributeUnsupported] {
            Owned.reset();let el=AXUIElement(1);el.actionStatus=status
            check(run(el,"AXConfirm",native:true) && Owned.trace == ["ax:1:AXConfirm"],"native perform status \(status.rawValue) accepted")
        }
        Owned.reset();let bad=AXUIElement(1);bad.actionStatus = .failure
        check(!run(bad,"AXConfirm",native:true),"native ordinary action error propagates")
        Owned.reset();let absent=AXUIElement(1);absent.supported.remove("AXDisclosing")
        check(run(absent,"SAIExpand",native:true) && Owned.writes.isEmpty && Owned.trace.isEmpty,"native unsupported disclosure is a no-op")
        Owned.reset();let nilValue=AXUIElement(1);nilValue.disclosing=nil
        check(run(nilValue,"SAICollapse",native:true) && Owned.writes == [true],"native unreadable disclosure defaults false then toggles")
        for raw in [NSNumber(value:0),NSNumber(value:1),NSNumber(value:2)] {
            Owned.reset();let el=AXUIElement(1);el.disclosing=raw
            check(run(el,"SAIExpand",native:true) && Owned.writes == [!((raw as? Bool) ?? false)],"native numeric disclosure bridge \(raw)")
        }
        for name in ["AXVisibleRows","AXVisibleChildren"] {
            Owned.reset();let a=AXUIElement(1,role:"AXMenuItem"),b=AXUIElement(2,role:"AXMenu"),c=AXUIElement(3)
            a.parent=b;b.actions=["AXPress"];b.supported.insert(name)
            if name=="AXVisibleRows"{b.visibleRows=[c]}else{b.visibleChildren=[c]}
            check(run(a,"AXPress",native:true) && Owned.trace == ["ax:1:AXPress"],"native nonempty \(name) stops ancestor forwarding")
        }
        Owned.reset();let a=AXUIElement(1,role:"AXMenuItem"),b=AXUIElement(2,role:"AXMenu")
        a.parent=b;b.actions=["AXPress"];b.supported.formUnion(["AXVisibleRows","AXVisibleChildren"]);b.children=[AXUIElement(3)]
        check(run(a,"AXPress",native:true) && Owned.trace == ["ax:1:AXPress"],"empty visible lists fall back to supported children")
        Owned.reset();b.supported.remove("AXChildren")
        check(run(a,"AXPress",native:true) && Owned.trace == ["ax:2:AXPress","ax:1:AXPress"],"unsupported children do not block menu forwarding")
        Owned.reset();let page=AXUIElement(1),bar=AXUIElement(2,role:"AXScrollBar"),button=AXUIElement(3,subrole:"AXIncrementPage")
        page.vertical=bar;bar.children=[button]
        check(run(page,"AXScrollDownByPage",native:true) && Owned.trace == ["ax:3:AXPress"],"native adapter routes page button through generic performer")
        Owned.reset();page.vertical=nil;page.horizontal=bar
        check(run(page,"AXScrollDownByPage",native:true) && Owned.trace == ["ax:1:AXScrollDownByPage"],"vertical scroll cannot borrow horizontal bar")
        Owned.reset();page.vertical=bar;button.subrole="AXIncrementPageExtra"
        check(run(page,"AXScrollDownByPage",native:true) && Owned.trace == ["ax:1:AXScrollDownByPage"],"page button subrole requires exact equality")
        Owned.reset();button.subrole="AXIncrementPage";let container=AXUIElement(4,role:"AXGroup");container.children=[button];bar.children=[container]
        check(run(page,"AXScrollDownByPage",native:true) && Owned.trace == ["ax:1:AXScrollDownByPage"],"page button lookup considers direct children only")
        Owned.reset();b.supported.insert("AXChildren");b.children=[AXUIElement(5)];b.countStatus = .failure;b.visibleRows=[AXUIElement(6)]
        check(run(a,"AXPress",native:true) && Owned.trace == ["ax:1:AXPress"],"failed visible count falls back to supported children")
        Owned.reset();b.namesStatus = .failure
        check(run(a,"AXPress",native:true) && Owned.trace == ["ax:1:AXPress"],"supported names use returned array despite status")
        Owned.reset();let unsupported=AXUIElement(7);unsupported.disclosable=false
        check(run(unsupported,"SAICollapse",native:true) && Owned.writes.isEmpty && Owned.trace == ["capability"],"native supported but unsettable disclosure is a no-op")
        Owned.reset();Owned.failRoutingID=7
        check(!run(unsupported,"SAIExpand",native:true) && Owned.trace.isEmpty && Owned.writes.isEmpty,"AX routing failure propagates before effects")
        let passed=rows.filter{$0["passed"] as? Bool == true}.count
        let report:[String:Any]=["checks":rows,"passed":passed,"failed":rows.count-passed,"direction_cases":expected.directions.count,"disclosure_cases":expected.disclosure.count,"disclosure_repeated_for_both_names":true,"native_AX_or_input_executed":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        if passed != rows.count {exit(1)}
    }
}
