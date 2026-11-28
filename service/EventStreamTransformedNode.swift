import Foundation
import ApplicationServices

/// A node wholly outside its window cannot be seen, whatever the app reports.
enum EventStreamOffscreen {
    static func whollyOutside(_ frame:CGRect,window:CGRect) -> Bool {
        func valid(_ rect:CGRect) -> Bool {
            [rect.minX,rect.minY,rect.width,rect.height].allSatisfy(\.isFinite) && rect.width>0 && rect.height>0
        }
        return valid(frame) && valid(window) && !frame.intersects(window)
    }
}

struct EventStreamNodeContext {
    var kind:UInt8=0
    var isCatalyst=false
    var isWebShaped=false
    var isChromium=false
    var parentRole:String?
    var windowFrame:CGRect?
    var valueContext:EventStreamValueContext {.init(kind:kind,isChromium:isChromium,parentRole:parentRole)}
}

struct EventStreamNodeAction {
    let name:String
    let description:String
    var kind:UInt8 {
        switch name {case "AXPress":return 0;case "AXShowMenu":return 1;case "AXScrollToVisible":return 2;default:return 3}
    }
    static let descriptions:[String:String] = [
        "AXPress":"Press","AXPick":"Pick","AXIncrement":"Increment","AXDecrement":"Decrement",
        "AXConfirm":"Confirm","AXCancel":"Cancel","AXShowDefaultUI":"Show Default UI",
        "AXShowAlternateUI":"Show Alternate UI","AXRaise":"Raise","AXShowMenu":"Show Menu",
        "AXScrollToVisible":"Scroll to Visible","AXScrollLeftByPage":"Scroll Left",
        "AXScrollRightByPage":"Scroll Right","AXScrollUpByPage":"Scroll Up","AXScrollDownByPage":"Scroll Down",
        "AXDelete":"Delete","SAIExpand":"Expand","SAICollapse":"Collapse"
    ]
    static func predefinedDescription(_ name:String) -> String? {
        if let known=descriptions[name] {return known}
        if name.hasPrefix("Name:") {
            let scanner=Scanner(string:name)
            if scanner.scanString("Name:") != nil {return scanner.scanUpToString("\n")}
        }
        return nil
    }
}

struct EventStreamTransformedNode<Element> {
    let element:Element
    var role="AXUnknown"
    var subrole:String?
    var roleDescription:String?
    var title:String?
    var description:String?
    var value:String?
    // 0x10076B344 tests the captured raw value via optional Bool conversion,
    // not its rendered type name. NSNumber 0/1 also suppress stringValue.
    var capturedValueIsBooleanConvertible=false
    var stringValue:String? {capturedValueIsBooleanConvertible ? nil:value}
    var truncationRange:NSRange?
    var valueDescription:String?
    var valueTypeName:String?
    var placeholderValue:String?
    var help:String?
    var identifier:String?
    var url:URL?
    var domClassList:[String]?
    var actionDescriptions:[EventStreamNodeAction]=[]
    var isSelected=false
    var isSelectable=false
    var isFocused=false
    var isFocusable=false
    var isEnabled=true
    var isDisclosing=false
    var isDisclosable=false
    var isValueSettable=false
    /// The node lies wholly outside its window: scrolled out of a list that
    /// the app does not expose as a scroll area, for example.
    var isOffscreen=false
    var attributedString:NSAttributedString?
    var transformedString:EventStreamTransformedString?

    var presentationState:EventStreamPresentationState {
        .init(isSelectable:isSelectable,isSelected:isSelected,isEnabled:isEnabled,
              isDisclosable:isDisclosable,isDisclosing:isDisclosing,
              valueTypeDescription:valueTypeName,isValueSettable:isValueSettable,
              isSentByMe:domClassList?.contains("is-sender") ?? false,isOffscreen:isOffscreen)
    }
    // URL shortening and row/column annotations are supplied by the complete
    // tree/presentation pipeline, not guessed by the native node constructor.
    func presentation(trimURL:(URL)->String?,rows:ClosedRange<Int>?=nil,columns:ClosedRange<Int>?=nil) -> EventStreamPresentation {
        .init(title:title,description:description,rows:rows,columns:columns,trimmedURL:url.flatMap(trimURL),
              help:help,value:value,details:valueDescription,placeholder:placeholderValue,identifier:identifier,
              actions:actionDescriptions.map {.init(kind:$0.kind,description:$0.description)})
    }
}

@MainActor protocol EventStreamNodeBackend:EventStreamValueBackend {
    func attributes(_ element:Element) -> [String:AnyObject]
    func isAttributeSettable(_ attribute:String,of element:Element) throws -> Bool
    func actions(_ element:Element) throws -> [String]
    func actionDescription(_ action:String,of element:Element) throws -> String?
}

//0x100768CCC and helper gates checked in assembly. Ordinary attribute fields
// consume the captured table; selective native reads honor requested versus
// supported metadata. The source element retains its transaction/partial data.
@MainActor struct EventStreamNodeConstruction<Backend:EventStreamNodeBackend> {
    let backend:Backend
    private static var selectableRoles:Set<String> {["AXCell","AXRadioButton","AXRow","AXTabGroup"]}
    private static func rectangle(_ raw:AnyObject?) -> CGRect? {
        guard let raw,CFGetTypeID(raw)==AXValueGetTypeID() else {return nil}
        let value=unsafeDowncast(raw,to:AXValue.self)
        var rect=CGRect.zero
        guard AXValueGetType(value) == .cgRect,AXValueGetValue(value,.cgRect,&rect) else {return nil}
        return rect
    }
    private static var focusableRoles:Set<String> {[
        "AXButton","AXCell","AXCheckBox","AXColorWell","AXComboBox","AXDateField","AXDateTimeArea",
        "AXDisclosureTriangle","AXDockItem","AXIncrementor","AXLink","AXMenuBarItem","AXMenuButton",
        "AXMenuItem","AXPopUpButton","AXRadioButton","AXRow","AXSlider","AXTabGroup","AXTextArea","AXTextField","AXTimeField"
    ]}
    func construct(_ element:Backend.Element,context:EventStreamNodeContext = .init()) -> EventStreamTransformedNode<Backend.Element> {
        let attributes=backend.attributes(element),snapshot=backend.snapshot(element)
        let constructedValue=EventStreamValueConstruction(backend:backend).construct(element,context:context.valueContext)
        func supports(_ name:String) -> Bool {
            EventStreamAttributeAvailability.supports(name,supported:snapshot.supported,requested:snapshot.transactionAttributes,
                                                      refresh:{backend.freshSupportedAttributes(element)})
        }
        func mayRead(_ name:String) -> Bool {
            EventStreamAttributeAvailability.mayRead(name,supported:snapshot.supported,requested:snapshot.transactionAttributes)
        }
        func traits() -> UInt64 {
            if let cached=attributes["AXTraits"] as? UInt64 {return cached}
            return mayRead("AXTraits") ? (backend.freshAttribute("AXTraits",of:element) as? UInt64 ?? 0):0
        }
        func settable(_ name:String) -> Bool {supports(name) && (try? backend.isAttributeSettable(name,of:element)) == true}
        var node=EventStreamTransformedNode(element:element)
        node.role=attributes["AXRole"] as? String ?? "AXUnknown";node.subrole=attributes["AXSubrole"] as? String
        node.roleDescription=attributes["AXRoleDescription"] as? String
        node.title=attributes["AXTitle"] as? String;node.description=attributes["AXDescription"] as? String
        node.value=constructedValue.value;node.truncationRange=constructedValue.truncationRange
        node.capturedValueIsBooleanConvertible=(attributes["AXValue"] as? Bool) != nil
        node.valueTypeName=constructedValue.kind?.rawValue;node.isValueSettable=constructedValue.isSettable
        node.valueDescription=attributes["AXValueDescription"] as? String
        node.placeholderValue=attributes["AXPlaceholderValue"] as? String;node.help=attributes["AXHelp"] as? String
        node.identifier=attributes["AXIdentifier"] as? String;node.url=attributes["AXURL"] as? URL
        if node.url==nil,node.role=="AXWindow" {
            let document=(attributes["AXDocument"] as? String) ?? (mayRead("AXDocument") ? backend.freshAttribute("AXDocument",of:element) as? String:nil)
            node.url=document.flatMap(URL.init(string:))
        }
        node.domClassList=attributes["AXDOMClassList"] as? [String]
        // A present invalid selected value does not fall back to traits.
        if let selected=attributes["AXSelected"] {node.isSelected=(selected as? Bool) ?? false}
        else {node.isSelected=traits() & 8 != 0}
        node.isFocused=(attributes["AXFocused"] as? Bool) ?? false
        node.isEnabled=(attributes["AXEnabled"] as? Bool) ?? true
        node.isDisclosing=(attributes["AXDisclosing"] as? Bool) ?? false
        // Only the prefetched frame is used; no extra read per node. Menus
        // and the menu bar live outside the window and are not marked.
        if let window=context.windowFrame,!node.role.hasPrefix("AXMenu"),
           let frame=Self.rectangle(attributes["AXFrame"]) {
            node.isOffscreen=EventStreamOffscreen.whollyOutside(frame,window:window)
        }
        if context.kind==1 {
            let flags=context.isCatalyst ? traits():0
            let selectedRelation=flags & 0x10100008 != 0 || !snapshot.supported.isDisjoint(with:["AXSelectedRows","AXSelectedCells","AXSelectedChildren"])
            node.isSelectable=Self.selectableRoles.contains(node.role) || (node.role=="AXGroup" && selectedRelation)
            node.isFocusable=(flags & 0x30810011141403 != 0) || Self.focusableRoles.contains(node.role) || (node.role=="AXGroup" && node.isSelectable)
            node.isDisclosable=node.isDisclosing || supports("AXDisclosing")
        } else {
            node.isSelectable = !["AXMenuItem","AXMenuBarItem"].contains(node.role) && settable("AXSelected")
            if supports("AXFocused") {
                do {node.isFocusable=try backend.isAttributeSettable("AXFocused",of:element)}
                catch {node.isFocusable=["AXTextArea","AXTextField","AXDateTimeArea"].contains(node.role) && node.isEnabled}
            }
            node.isDisclosable=settable("AXDisclosing")
            if context.kind==0 {
                // Enumeration errors return an empty array before the
                // synthetic disclosure append (0x10079B368 error tail).
                if var names=try? backend.actions(element) {
                    if node.isDisclosable {names.append(node.isDisclosing ? "SAICollapse":"SAIExpand")}
                    node.actionDescriptions=names.map {name in
                        .init(name:name,description:EventStreamNodeAction.predefinedDescription(name)
                            ?? ((try? backend.actionDescription(name,of:element)) ?? nil) ?? name)
                    }
                }
            }
        }
        return node
    }
}
