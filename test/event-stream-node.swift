import Foundation

@MainActor final class NodeBackend:EventStreamNodeBackend {
    typealias Element=Int
    enum Failure:Error {case native}
    var captured:[String:AnyObject]=[:],supported:Set<String>=[],requested:Set<String>?
    var fresh:[String:AnyObject]=[:],freshSupported:Set<String>=[],settable:Set<String>=[],setterErrors:Set<String>=[]
    var names:[String]=[],descriptions:[String:String]=[:],failNames=false,failDescriptions=false
    var reads:[String]=[],setterCalls:[String]=[],discoveryCalls=0,actionCalls=0,descriptionCalls:[String]=[]
    func attributes(_ element:Int)->[String:AnyObject] {captured}
    func snapshot(_ element:Int)->EventStreamValueSnapshot {
        .init(role:captured["AXRole"] as? String ?? "AXUnknown",subrole:captured["AXSubrole"] as? String,
              value:captured["AXValue"],supported:supported,transactionAttributes:requested)
    }
    func freshAttribute(_ attribute:String,of element:Int)->AnyObject? {reads.append(attribute);return fresh[attribute]}
    func freshSupportedAttributes(_ element:Int)->Set<String> {discoveryCalls += 1;return freshSupported}
    func isAttributeSettable(_ attribute:String,of element:Int)throws->Bool {setterCalls.append(attribute);if setterErrors.contains(attribute) {throw Failure.native};return settable.contains(attribute)}
    func isValueSettable(_ element:Int)->Bool {(try? isAttributeSettable("AXValue",of:element)) == true}
    func string(_ element:Int,for range:NSRange)->String? {nil}
    func format(_ date:Date,style:EventStreamValueDateStyle)->String {"date"}
    func actions(_ element:Int)throws->[String] {actionCalls += 1;if failNames {throw Failure.native};return names}
    func actionDescription(_ action:String,of element:Int)throws->String? {descriptionCalls.append(action);if failDescriptions {throw Failure.native};return descriptions[action]}
    func reset(_ role:String="AXGroup") {
        captured=["AXRole":role as NSString];supported=[];requested=nil;fresh=[:];freshSupported=[];settable=[];setterErrors=[];names=[];descriptions=[:];failNames=false;failDescriptions=false;reads=[];setterCalls=[];discoveryCalls=0;actionCalls=0;descriptionCalls=[]
    }
}
@main enum NodeTests {
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ value:@autoclosure ()->Bool) {
        let okay=value();if !okay {fputs("FAIL: \(label)\n",stderr)};precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    @MainActor static func main() {
        setbuf(stdout,nil);let b=NodeBackend(),builder=EventStreamNodeConstruction(backend:b)
        let event=EventStreamNodeContext(kind:1),catalyst=EventStreamNodeContext(kind:1,isCatalyst:true)
        b.reset();var node=builder.construct(7,context:event)
        check("source element identity is retained",node.element==7)
        check("missing boolean defaults match constructor",!node.isSelected && !node.isFocused && node.isEnabled && !node.isDisclosing)
        check("untransformed strings and attributed payload start nil",node.attributedString==nil && node.transformedString==nil)
        b.captured=[:];check("missing role falls back to AXUnknown",builder.construct(0,context:event).role=="AXUnknown")
        b.captured=["AXRole":NSNumber(value:1)];check("invalid role type does not stringify",builder.construct(0,context:event).role=="AXUnknown")
        b.reset("AXTextField");b.captured.merge(["AXSubrole":"sub" as NSString,"AXRoleDescription":"text field" as NSString,"AXTitle":" title " as NSString,"AXDescription":"desc" as NSString,"AXValue":"body" as NSString,"AXValueDescription":"details" as NSString,"AXPlaceholderValue":"hint" as NSString,"AXHelp":"help" as NSString,"AXIdentifier":"field-id" as NSString]) {_,new in new}
        node=builder.construct(0,context:event)
        check("cached descriptive fields preserve original strings",node.subrole=="sub" && node.roleDescription=="text field" && node.title==" title " && node.description=="desc")
        check("value constructor is integrated into node",node.value=="body" && node.valueTypeName=="string" && node.isValueSettable)
        check("detail placeholder help and identifier are captured",node.valueDescription=="details" && node.placeholderValue=="hint" && node.help=="help" && node.identifier=="field-id")
        b.captured["AXTitle"]="changed" as NSString;check("constructed snapshot does not change with backend table",node.title==" title ")
        b.reset();b.captured["AXDOMClassList"]=["one","two"] as NSArray
        check("DOM string array is preserved",builder.construct(0,context:event).domClassList==["one","two"])
        b.captured["AXDOMClassList"]=[1,2] as NSArray;check("invalid DOM list is not coerced",builder.construct(0,context:event).domClassList==nil)
        b.reset("AXWindow");b.captured["AXURL"]=URL(string:"https://cached.example/a")! as NSURL;b.captured["AXDocument"]="https://document.example/b" as NSString
        node=builder.construct(0,context:event)
        check("cached NSURL takes priority over document",node.url?.host=="cached.example" && !b.reads.contains("AXDocument"))
        b.captured["AXURL"]="https://string.example" as NSString
        check("window document fallback parses captured string",builder.construct(0,context:event).url?.host=="document.example")
        b.reset("AXButton");b.captured["AXURL"]="https://string.example" as NSString;b.fresh["AXDocument"]="https://native.example" as NSString
        check("AXURL string is not coerced and nonwindow skips document",builder.construct(0,context:event).url==nil && !b.reads.contains("AXDocument"))
        b.reset("AXWindow");b.supported=["AXTitle"];b.requested=["AXDocument"];b.fresh["AXDocument"]="https://native.example" as NSString
        check("requested unsupported document avoids native query",builder.construct(0,context:event).url==nil && !b.reads.contains("AXDocument"))
        b.requested=[];check("unrequested document can be read outside capability subset",builder.construct(0,context:event).url?.host=="native.example" && b.reads.contains("AXDocument"))
        b.reset("AXWindow");b.captured["AXDocument"]="relative/file.txt" as NSString
        check("document fallback preserves relative URL semantics",builder.construct(0,context:event).url?.relativeString=="relative/file.txt")
        b.reset();b.captured["AXTraits"]=NSNumber(value:8)
        check("absent selected state falls back to selected trait",builder.construct(0,context:event).isSelected)
        b.captured["AXSelected"]=kCFBooleanFalse
        check("explicit unselected overrides selected trait",!builder.construct(0,context:event).isSelected)
        b.captured["AXSelected"]=NSNull();check("present invalid selection does not fall back to traits",!builder.construct(0,context:event).isSelected)
        b.reset();b.supported=["AXTraits"];b.fresh["AXTraits"]=NSNumber(value:8)
        check("missing cached trait can query supported native trait",builder.construct(0,context:event).isSelected && b.reads==["AXTraits"])
        b.reset();b.supported=["AXRole"];b.requested=["AXTraits"];b.fresh["AXTraits"]=NSNumber(value:8)
        check("requested unsupported trait is not queried again",!builder.construct(0,context:event).isSelected && b.reads.isEmpty)
        b.reset();b.captured["AXFocused"]=kCFBooleanTrue;b.captured["AXEnabled"]=kCFBooleanFalse;b.captured["AXDisclosing"]=kCFBooleanTrue
        node=builder.construct(0,context:event)
        check("captured focus enabled and expansion states are used",node.isFocused && !node.isEnabled && node.isDisclosing && node.isDisclosable)
        b.captured["AXEnabled"]=NSNull();check("invalid enabled value defaults enabled",builder.construct(0,context:event).isEnabled)
        let selectable=["AXCell","AXRadioButton","AXRow","AXTabGroup"]
        check("event selectable roles use the four-role set",selectable.allSatisfy {b.reset($0);return builder.construct(0,context:event).isSelectable})
        b.reset("AXGroup");check("ordinary group is not selectable or focusable",!builder.construct(0,context:event).isSelectable && !builder.construct(0,context:event).isFocusable)
        b.supported=["AXSelectedChildren"];node=builder.construct(0,context:event)
        check("group selection relation implies selection and focus capability",node.isSelectable && node.isFocusable)
        b.reset("AXGroup");b.captured["AXTraits"]=NSNumber(value:8)
        check("Catalyst selected trait supplies group selection capability",builder.construct(0,context:catalyst).isSelectable)
        check("same trait does not infer group capability outside Catalyst",!builder.construct(0,context:event).isSelectable)
        b.reset("AXUnknown");b.captured["AXTraits"]=NSNumber(value:1)
        check("Catalyst focus trait can focus unknown role",builder.construct(0,context:catalyst).isFocusable)
        check("focus trait inference is limited to Catalyst",!builder.construct(0,context:event).isFocusable)
        b.reset("AXTextField");node=builder.construct(0,context:event)
        check("event text field infers focus without setter query",node.isFocusable && b.setterCalls.isEmpty)
        b.reset("AXUnknown");b.supported=["AXTraits"];b.fresh["AXTraits"]=NSNumber(value:1)
        _=builder.construct(0,context:catalyst)
        check("uncached trait observations keep two-read ordering",b.reads==["AXTraits","AXTraits"])
        b.reset();b.supported=["AXDisclosing"];node=builder.construct(0,context:event)
        check("event disclosure capability uses advertised attribute",node.isDisclosable && b.setterCalls.isEmpty)
        b.reset();b.supported=["AXRole"];b.requested=[];b.freshSupported=["AXDisclosing"]
        check("unrequested disclosure capability is freshly discovered",builder.construct(0,context:event).isDisclosable && b.discoveryCalls==1)
        b.requested=["AXDisclosing"];b.discoveryCalls=0
        check("requested unsupported disclosure avoids rediscovery",!builder.construct(0,context:event).isDisclosable && b.discoveryCalls==0)
        b.reset("AXButton");b.supported=["AXSelected","AXFocused","AXDisclosing"];b.settable=b.supported
        node=builder.construct(0)
        check("full context queries three native capabilities",node.isSelectable && node.isFocusable && node.isDisclosable && b.setterCalls==["AXSelected","AXFocused","AXDisclosing"])
        b.reset("AXMenuItem");b.supported=["AXSelected"];b.settable=["AXSelected"]
        check("menu item is excluded from native selectable inference",!builder.construct(0).isSelectable && !b.setterCalls.contains("AXSelected"))
        b.reset("AXTextField");b.supported=["AXFocused"];b.setterErrors=["AXFocused"]
        check("text focus query error falls back to enabled state",builder.construct(0).isFocusable)
        b.captured["AXEnabled"]=kCFBooleanFalse;check("disabled text does not get focus error fallback",!builder.construct(0).isFocusable)
        b.reset("AXButton");b.supported=["AXFocused"];b.setterErrors=["AXFocused"]
        check("ordinary role focus query error defaults false",!builder.construct(0).isFocusable)
        b.reset("AXTextField");b.supported=["AXFocused"]
        check("successful negative focus response does not use enabled fallback",!builder.construct(0).isFocusable)
        check("textarea and datetime roles share focus-error enabled fallback",["AXTextArea","AXDateTimeArea"].allSatisfy {role in b.reset(role);b.supported=["AXFocused"];b.setterErrors=["AXFocused"];return builder.construct(0).isFocusable})
        b.reset();b.captured["AXDisclosing"]=kCFBooleanTrue
        check("full context expanded state does not imply native disclosure capability",!builder.construct(0).isDisclosable)
        b.reset();b.supported=["AXDisclosing"];b.settable=["AXDisclosing"];b.names=["AXPress","AXUnknown"]
        b.descriptions["AXUnknown"]="Custom Action";node=builder.construct(0)
        check("native actions preserve order and append synthetic expand",node.actionDescriptions.map(\.name)==["AXPress","AXUnknown","SAIExpand"])
        check("known actions bypass native descriptions",node.actionDescriptions[0].description=="Press" && b.descriptionCalls==["AXUnknown"])
        check("unknown action uses native description",node.actionDescriptions[1].description=="Custom Action")
        b.captured["AXDisclosing"]=kCFBooleanTrue;check("expanded node appends synthetic collapse",builder.construct(0).actionDescriptions.last?.name=="SAICollapse")
        b.names=["SAICollapse"];check("synthetic action append does not deduplicate native names",builder.construct(0).actionDescriptions.map(\.name)==["SAICollapse","SAICollapse"])
        b.failNames=true
        check("action enumeration error omits synthetic disclosure too",builder.construct(0).actionDescriptions.isEmpty)
        b.reset();b.names=["Name:   Special action\nother metadata","unknown"]
        node=builder.construct(0)
        check("encoded action name uses Scanner label extraction",node.actionDescriptions[0].description=="Special action")
        check("missing native action description falls back to name",node.actionDescriptions[1].description=="unknown")
        b.failDescriptions=true;check("native description error falls back to raw action name",builder.construct(0).actionDescriptions[1].description=="unknown")
        b.reset();b.names=["AXPress"]
        check("event context never collects action names",builder.construct(0,context:event).actionDescriptions.isEmpty && b.actionCalls==0)
        check("informational context also omits actions",builder.construct(0,context:.init(kind:2)).actionDescriptions.isEmpty && b.actionCalls==0)
        b.reset();b.names=["AXPress","AXShowMenu","AXScrollToVisible","AXDelete"]
        node=builder.construct(0)
        check("presentation action kinds preserve enum order",node.actionDescriptions.map(\.kind)==[0,1,2,3])
        b.reset();b.failDescriptions=true
        b.names=["AXPress","AXPick","AXIncrement","AXDecrement","AXConfirm","AXCancel","AXShowDefaultUI","AXShowAlternateUI","AXRaise","AXShowMenu","AXScrollToVisible","AXScrollLeftByPage","AXScrollRightByPage","AXScrollUpByPage","AXScrollDownByPage","AXDelete","SAIExpand","SAICollapse"]
        node=builder.construct(0)
        check("all known action labels bypass failing native descriptions",node.actionDescriptions.map(\.description)==["Press","Pick","Increment","Decrement","Confirm","Cancel","Show Default UI","Show Alternate UI","Raise","Show Menu","Scroll to Visible","Scroll Left","Scroll Right","Scroll Up","Scroll Down","Delete","Expand","Collapse"] && b.descriptionCalls.isEmpty)
        b.reset("AXButton");b.captured["AXRoleDescription"]="button" as NSString;b.captured["AXTitle"]="Go" as NSString;b.names=["AXPress","AXDelete"]
        node=builder.construct(0);let presentation=node.presentation(trimURL:{$0.absoluteString})
        check("constructed node reaches transformed presentation",presentation.accessibilityDescription(role:.init(nativeRole:node.role,roleDescription:node.roleDescription),state:node.presentationState,contextKind:0,hasDescriptiveAttributes:true)=="button Go, Secondary Actions: Delete")
        print("EVENT STREAM TRANSFORMED NODES: \(checks) checks passed")
    }
}
