import Foundation
import ApplicationServices

struct EventStreamValueContext {
    var kind:UInt8 = 0
    var isChromium=false
    var parentRole:String?
}

struct EventStreamValueSnapshot {
    var role="AXUnknown"
    var subrole:String?
    var value:AnyObject?
    var coverage:EventStreamPartialValue.StringCoverage?
    var supported:Set<String> = []
    var transactionAttributes:Set<String>?
    var visibleRange:NSRange?
    var dateTimeComponents:Int?
}

struct EventStreamTransformedValue {
    enum Kind:String {case float,integer,boolean,string,date,unknown}
    let value:String?
    let kind:Kind?
    let truncationRange:NSRange?
    let isSettable:Bool

    static func classify(_ snapshot:EventStreamValueSnapshot) -> Kind {
        guard let value=snapshot.value else {return ["AXTextField","AXTextArea"].contains(snapshot.role) ? .string:.unknown}
        if snapshot.role=="AXCheckBox",["AXSwitch","AXToggle"].contains(snapshot.subrole ?? "") {return .boolean}
        let type=CFGetTypeID(value)
        if type==CFNumberGetTypeID() {return CFNumberIsFloatType(unsafeBitCast(value,to:CFNumber.self)) ? .float:.integer}
        if type==CFBooleanGetTypeID() {return .boolean}
        if type==CFStringGetTypeID() {return .string}
        if type==CFDateGetTypeID() {return .date}
        return .unknown
    }
}

@MainActor protocol EventStreamValueBackend {
    associatedtype Element
    func snapshot(_ element:Element) -> EventStreamValueSnapshot
    func freshAttribute(_ attribute:String,of element:Element) -> AnyObject?
    func freshSupportedAttributes(_ element:Element) -> Set<String>
    func isValueSettable(_ element:Element) -> Bool
    func string(_ element:Element,for range:NSRange) -> String?
    func format(_ date:Date,style:EventStreamValueDateStyle) -> String
}

enum EventStreamValueDateStyle:UInt8 {
    case date,time,dateAndTime,monthAndYear
    // AXDateTimeComponents, including its non-enumerated fallback.
    static func selected(_ components:Int?) -> Self {
        switch components {
        case 12,14:return .time
        case 192:return .monthAndYear
        case 224:return .date
        default:return .dateAndTime
        }
    }
    func formatter() -> DateFormatter {
        let formatter=DateFormatter()
        switch self {
        case .date:formatter.dateStyle = .short;formatter.timeStyle = .none
        case .time:formatter.dateStyle = .none;formatter.timeStyle = .short
        case .dateAndTime:formatter.dateStyle = .short;formatter.timeStyle = .short
        case .monthAndYear:formatter.dateFormat="MMMM yyyy"
        }
        return formatter
    }
}

// Native value construction, conversion and string truncation. No
// automation text budget is substituted for the transformed-tree threshold
// of 100000. A positive visible range can be larger than that threshold.
@MainActor struct EventStreamValueConstruction<Backend:EventStreamValueBackend> {
    let backend:Backend
    private static var editableRoles:Set<String> {
        ["AXComboBox","AXDateField","AXDateTimeArea","AXIncrementor","AXSlider","AXTextArea","AXTextField","AXTimeField"]
    }
    func construct(_ element:Backend.Element,context:EventStreamValueContext = .init()) -> EventStreamTransformedValue {
        let snapshot=backend.snapshot(element)
        // Constructor does not assign a type name or query settability unless
        // the value key was actually captured. NSNull is a present value.
        guard let raw=snapshot.value else {return .init(value:nil,kind:nil,truncationRange:nil,isSettable:false)}
        let kind=EventStreamTransformedValue.classify(snapshot)
        var settable=false
        if !context.isChromium || chromiumEditable(snapshot,context:context) {
            if context.kind==1 {settable=Self.editableRoles.contains(snapshot.role)}
            else {
                if EventStreamAttributeAvailability.supports("AXValue",supported:snapshot.supported,
                    requested:snapshot.transactionAttributes,refresh:{backend.freshSupportedAttributes(element)}) {
                    settable=backend.isValueSettable(element)
                }
            }
        }
        var value:String?,truncation:NSRange?
        if CFGetTypeID(raw)==CFStringGetTypeID(),let text=raw as? String {
            (value,truncation)=string(text,element:element,snapshot:snapshot)
        } else {
            switch kind {
            case .float,.integer:value=(raw as? NSNumber)?.stringValue
            case .boolean:
                // The reference force-casts a switch/toggle's value to
                // CFBoolean. Reject malformed nonboolean data without a trap.
                if CFGetTypeID(raw)==CFBooleanGetTypeID() {value=(raw as? NSNumber)?.boolValue == true ? "on":"off"}
            case .string:value=raw as? String
            case .date:
                if let date=raw as? Date {
                    let components=snapshot.dateTimeComponents ?? (mayRead("AXDateTimeComponents",snapshot:snapshot) ? backend.freshAttribute("AXDateTimeComponents",of:element) as? Int:nil)
                    value=backend.format(date,style:.selected(components))
                }
            case .unknown:break
            }
        }
        if truncation != nil {settable=false}
        return .init(value:value,kind:kind,truncationRange:truncation,isSettable:settable)
    }
    private func chromiumEditable(_ snapshot:EventStreamValueSnapshot,context:EventStreamValueContext) -> Bool {
        if snapshot.role=="AXIncrementor",["AXDateField","AXDateTimeArea","AXTimeField"].contains(context.parentRole ?? "") {return false}
        if ["AXComboBox","AXIncrementor","AXTextArea","AXTextField"].contains(snapshot.role) {return true}
        return snapshot.role=="AXRadioButton" && snapshot.subrole=="AXTabButton"
    }
    private func mayRead(_ attribute:String,snapshot:EventStreamValueSnapshot) -> Bool {
        EventStreamAttributeAvailability.mayRead(attribute,supported:snapshot.supported,requested:snapshot.transactionAttributes)
    }
    private func string(_ text:String,element:Backend.Element,snapshot:EventStreamValueSnapshot) -> (String?,NSRange?) {
        guard ["AXTextArea","AXTextField","AXStaticText"].contains(snapshot.role) else {return (text,nil)}
        let total=snapshot.coverage?.count ?? text.utf16.count
        if max(text.count,total)<=100000 {
            if let coverage=snapshot.coverage,coverage.availableRange.count<total {
                if mayRead("AXValue",snapshot:snapshot),let fresh=backend.freshAttribute("AXValue",of:element) as? String {return (fresh,nil)}
                return (text,NSRange(location:coverage.availableRange.lowerBound,length:coverage.availableRange.count))
            }
            return (text,nil)
        }
        let visible=snapshot.visibleRange ?? (mayRead("AXVisibleCharacterRange",snapshot:snapshot) ? range(backend.freshAttribute("AXVisibleCharacterRange",of:element)):nil)
        let selected=visible.flatMap {$0.length>0 ? $0:nil} ?? NSRange(location:0,length:100000)
        let end=selected.location.addingReportingOverflow(selected.length)
        // Invalid/overflowing native ranges are rejected instead of trapping on
        // arithmetic or indexing. Valid ranges keep the mixed Character-count test
        // followed by UTF16 Range conversion.
        guard selected.location>=0,selected.length>=0,!end.overflow else {return (nil,selected)}
        if text.count>=end.partialValue {
            guard let range=Range(selected,in:text) else {return (nil,selected)}
            return (String(text[range]),selected)
        }
        return (backend.string(element,for:selected),selected)
    }
    private func range(_ raw:AnyObject?) -> NSRange? {
        guard let raw,CFGetTypeID(raw)==AXValueGetTypeID() else {return nil}
        let value=unsafeBitCast(raw,to:AXValue.self);var range=CFRange()
        guard AXValueGetType(value) == .cfRange,AXValueGetValue(value,.cfRange,&range) else {return nil}
        return NSRange(location:range.location == -1 ? NSNotFound:range.location,length:range.length)
    }
}
