import Foundation
import ApplicationServices

@MainActor final class ValueBackend:EventStreamValueBackend {
    typealias Element=Int
    var input=EventStreamValueSnapshot(role:"AXTextField",value:"short" as NSString,supported:["AXValue"])
    var attributes:[String:AnyObject]=[:],supported:Set<String>=[],settable=true,ranged:String?
    var reads:[String]=[],ranges:[NSRange]=[],settableReads=0,supportedReads=0,dateStyles:[EventStreamValueDateStyle]=[]
    func snapshot(_ element:Int) -> EventStreamValueSnapshot {input}
    func freshAttribute(_ attribute:String,of element:Int) -> AnyObject? {reads.append(attribute);return attributes[attribute]}
    func freshSupportedAttributes(_ element:Int) -> Set<String> {supportedReads += 1;return supported}
    func isValueSettable(_ element:Int) -> Bool {settableReads += 1;return settable}
    func string(_ element:Int,for range:NSRange) -> String? {ranges.append(range);return ranged}
    func format(_ date:Date,style:EventStreamValueDateStyle) -> String {dateStyles.append(style);return "formatted-\(style.rawValue)"}
    func reset() {attributes=[:];supported=[];settable=true;ranged=nil;reads=[];ranges=[];settableReads=0;supportedReads=0;dateStyles=[]}
}
@main enum ValueTests {
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    @MainActor static func main() {
        setbuf(stdout,nil)
        let b=ValueBackend(),construction=EventStreamValueConstruction(backend:b)
        func value(_ raw:AnyObject?,role:String="AXTextField",subrole:String?=nil,context:EventStreamValueContext = .init()) -> EventStreamTransformedValue {
            b.reset();b.input = .init(role:role,subrole:subrole,value:raw,supported:["AXValue"])
            return construction.construct(0,context:context)
        }
        check("integer class and signed formatting",value(NSNumber(value:-42)).kind == .integer && value(NSNumber(value:-42)).value=="-42")
        check("floating class and decimal formatting",value(NSNumber(value:1.25)).kind == .float && value(NSNumber(value:1.25)).value=="1.25")
        check("boolean true uses on",value(kCFBooleanTrue).value=="on" && value(kCFBooleanTrue).kind == .boolean)
        check("boolean false uses off",value(kCFBooleanFalse).value=="off")
        check("numeric zero remains integer instead of boolean",value(NSNumber(value:0)).value=="0" && value(NSNumber(value:0)).kind == .integer)
        check("actual string is preserved",value("A😀e\u{301}" as NSString).value=="A😀e\u{301}")
        check("absent value leaves type and settability absent",value(nil).kind==nil && !value(nil).isSettable && b.settableReads==0)
        check("NSNull is a present unknown value",value(NSNull()).kind == .unknown && value(NSNull()).value==nil)
        check("unknown object does not stringify arbitrary contents",value([1,2] as NSArray).value==nil && value([1,2] as NSArray).kind == .unknown)
        check("switch subrole forces boolean type",value(kCFBooleanTrue,role:"AXCheckBox",subrole:"AXSwitch").kind == .boolean)
        check("toggle malformed number is rejected without forced cast trap",value(NSNumber(value:1),role:"AXCheckBox",subrole:"AXToggle").value==nil)
        check("switch string follows constructor string branch",value("1" as NSString,role:"AXCheckBox",subrole:"AXSwitch").value=="1")
        b.reset();b.input = .init(role:"AXTextField",value:"edit" as NSString,supported:["AXValue"])
        check("full context queries actual native settability",construction.construct(0).isSettable && b.settableReads==1)
        b.settable=false;check("native nonsettable result is respected",!construction.construct(0).isSettable)
        b.reset();b.input.supported=[]
        check("no capability marker and unsupported value skip setter query",!construction.construct(0).isSettable && b.settableReads==0 && b.supportedReads==0)
        b.input.transactionAttributes=[];b.supported=["AXValue"]
        check("prefetch marker permits fresh capability discovery",construction.construct(0).isSettable && b.supportedReads==1)
        b.supported=[];check("fresh discovery can reject value settability",!construction.construct(0).isSettable)
        b.reset();b.input = .init(role:"AXTextField",value:"edit" as NSString,supported:[])
        check("event context infers editable text without AX setter call",construction.construct(0,context:.init(kind:1)).isSettable && b.settableReads==0)
        b.input.role="AXSlider";check("event context includes editable slider",construction.construct(0,context:.init(kind:1)).isSettable)
        b.input.role="AXButton";check("event context excludes arbitrary button value",!construction.construct(0,context:.init(kind:1)).isSettable)
        b.input.supported=["AXValue"]
        check("Chromium excludes button before setter call",!construction.construct(0,context:.init(isChromium:true)).isSettable && b.settableReads==0)
        b.input.role="AXTextArea";check("Chromium permits textarea",construction.construct(0,context:.init(isChromium:true)).isSettable)
        b.input.role="AXIncrementor";check("Chromium excludes incrementor inside date field",!construction.construct(0,context:.init(isChromium:true,parentRole:"AXDateField")).isSettable)
        check("Chromium permits incrementor without date parent",construction.construct(0,context:.init(isChromium:true)).isSettable)
        b.input.role="AXRadioButton";b.input.subrole="AXTabButton"
        check("Chromium permits tab radio subrole",construction.construct(0,context:.init(isChromium:true)).isSettable)
        b.input.subrole=nil;check("Chromium excludes ordinary radio",!construction.construct(0,context:.init(isChromium:true)).isSettable)
        b.reset();b.input = .init(role:"AXTextField",value:"prefix" as NSString,coverage:.init(count:30,availableRange:0..<6),supported:["AXValue"])
        b.attributes["AXValue"]="complete value" as NSString
        var result=construction.construct(0)
        check("small partial text refetches complete AXValue",result.value=="complete value" && result.truncationRange==nil && b.reads==["AXValue"])
        check("successful full refetch retains editing capability",result.isSettable)
        b.attributes=[:];result=construction.construct(0)
        check("failed refetch preserves original partial coverage",result.value=="prefix" && result.truncationRange==NSRange(location:0,length:6))
        check("partial result is never advertised settable",!result.isSettable)
        b.reset();b.input.supported=["AXTitle"]
        result=construction.construct(0)
        check("known unsupported partial value avoids fresh read",b.reads.isEmpty && result.truncationRange != nil)
        b.input.transactionAttributes=[];b.attributes["AXValue"]="refetched" as NSString
        result=construction.construct(0)
        check("prefetch marker allows partial recovery outside captured capability subset",result.value=="refetched" && b.reads==["AXValue"])
        b.reset();b.input.supported=[];b.input.transactionAttributes=nil;b.attributes["AXValue"]="discovered" as NSString
        check("unknown empty capabilities permit partial recovery",construction.construct(0).value=="discovered")
        let large=String(repeating:"x",count:100001)
        b.reset();b.input = .init(role:"AXTextArea",value:large as NSString,supported:["AXValue"],visibleRange:NSRange(location:23,length:17))
        result=construction.construct(0)
        check("large text prefers visible cached UTF16 range",result.value==String(repeating:"x",count:17) && result.truncationRange==NSRange(location:23,length:17))
        check("large cached slice avoids parameter read",b.ranges.isEmpty)
        check("truncated slice is not editable",!result.isSettable)
        b.input.visibleRange=nil;result=construction.construct(0)
        check("large text defaults to first100000 units",result.value?.utf16.count==100000 && result.truncationRange==NSRange(location:0,length:100000))
        b.input.visibleRange=NSRange(location:20,length:0);check("empty visible range uses100000-unit fallback",construction.construct(0).truncationRange==NSRange(location:0,length:100000))
        var nativeVisible=CFRange(location:31,length:14)
        b.input.visibleRange=nil;b.input.supported.insert("AXVisibleCharacterRange")
        b.attributes["AXVisibleCharacterRange"]=AXValueCreate(.cfRange,&nativeVisible)!
        result=construction.construct(0)
        check("uncached visible AX range is decoded before slicing",result.truncationRange==NSRange(location:31,length:14) && result.value?.count==14 && b.reads.contains("AXVisibleCharacterRange"))
        b.input.visibleRange=NSRange(location:0,length:100001)
        result=construction.construct(0)
        check("positive visible range may exceed100000 threshold",result.value?.count==100001 && result.truncationRange?.length==100001)
        b.input.visibleRange=NSRange(location:0,length:100002);b.ranged="beyond cached";b.ranges=[]
        result=construction.construct(0)
        check("visible range larger than cached string uses parameter backend",result.value=="beyond cached" && b.ranges==[NSRange(location:0,length:100002)])
        b.reset();b.input = .init(role:"AXStaticText",value:"truncated" as NSString,coverage:.init(count:200000,availableRange:0..<9),supported:["AXVisibleCharacterRange"],visibleRange:NSRange(location:150000,length:50));b.ranged="native visible slice"
        result=construction.construct(0)
        check("slice outside cached text uses parameterized native read",b.ranges==[NSRange(location:150000,length:50)] && result.value=="native visible slice")
        check("parameterized slice retains requested range",result.truncationRange==NSRange(location:150000,length:50))
        b.ranged=nil;check("failed parameterized read returns nil with truncation marker",construction.construct(0).value==nil && construction.construct(0).truncationRange != nil)
        b.input.visibleRange=NSRange(location:Int.max,length:1);b.ranges=[]
        check("overflowing native range is rejected without parameter call",construction.construct(0).value==nil && b.ranges.isEmpty)
        b.input = .init(role:"AXTextArea",value:(String(repeating:"a",count:99999)+"😀") as NSString,supported:["AXValue"])
        result=construction.construct(0)
        check("surrogate-splitting range rounds substring down while retaining requested coverage",result.value==String(repeating:"a",count:99999) && result.truncationRange==NSRange(location:0,length:100000))
        b.input = .init(role:"AXTextField",value:String(repeating:"😀",count:100000) as NSString,supported:["AXValue"])
        result=construction.construct(0)
        check("Character-bound and UTF16 conversion produce 50000 emojis",result.value?.count==50000 && result.truncationRange?.length==100000)
        b.input = .init(role:"AXTextField",value:String(repeating:"x",count:100000) as NSString,supported:["AXValue"])
        check("exact100000-unit boundary is not truncated",construction.construct(0).truncationRange==nil && construction.construct(0).isSettable)
        b.input.role="AXButton";b.input.value=large as NSString
        check("nontext roles retain large values without text truncation",construction.construct(0).value==large && construction.construct(0).truncationRange==nil)
        let date=Date(timeIntervalSince1970:0)
        b.reset();b.input = .init(value:date as NSDate,supported:["AXDateTimeComponents"],dateTimeComponents:12)
        result=construction.construct(0)
        check("date type selects cached time components",result.kind == .date && result.value=="formatted-1" && b.reads.isEmpty)
        b.input.dateTimeComponents=nil;b.attributes["AXDateTimeComponents"]=NSNumber(value:224)
        check("uncached supported date components choose date-only",construction.construct(0).value=="formatted-0" && b.reads==["AXDateTimeComponents"])
        b.attributes["AXDateTimeComponents"]=NSNumber(value:192);check("month-year components choose month-year style",construction.construct(0).value=="formatted-3")
        check("missing components default date-and-time",EventStreamValueDateStyle.selected(nil) == .dateAndTime)
        check("time component variants12and14",EventStreamValueDateStyle.selected(12) == .time && EventStreamValueDateStyle.selected(14) == .time)
        check("date-and-time component variants236and238",EventStreamValueDateStyle.selected(236) == .dateAndTime && EventStreamValueDateStyle.selected(238) == .dateAndTime)
        check("unknown component combination keeps the date-and-time fallback",EventStreamValueDateStyle.selected(777) == .dateAndTime)
        let dateFormatter=EventStreamValueDateStyle.date.formatter(),timeFormatter=EventStreamValueDateStyle.time.formatter(),both=EventStreamValueDateStyle.dateAndTime.formatter(),month=EventStreamValueDateStyle.monthAndYear.formatter()
        check("native date formatter uses short date only",dateFormatter.dateStyle == .short && dateFormatter.timeStyle == .none)
        check("native time formatter uses short time only",timeFormatter.dateStyle == .none && timeFormatter.timeStyle == .short)
        check("native combined formatter uses short styles",both.dateStyle == .short && both.timeStyle == .short)
        check("native month-year formatter keeps the MMMM yyyy format",month.dateFormat=="MMMM yyyy")
        _=value("visible" as NSString);result=construction.construct(0,context:.init(kind:1))
        let presentation=EventStreamPresentation(value:result.value)
        let state=EventStreamPresentationState(valueTypeDescription:result.kind?.rawValue,isValueSettable:result.isSettable)
        check("constructed value and editable state feed transformed presentation",presentation.accessibilityDescription(role:.init(nativeRole:"AXTextField",roleDescription:"text field"),state:state,contextKind:1,hasDescriptiveAttributes:true)=="text field (settable) visible")
        b.reset();b.input = .init(value:"raw" as NSString,supported:["AXValue"],transactionAttributes:[])
        check("unrequested value capability is rediscovered even if captured",!construction.construct(0).isSettable && b.supportedReads==1 && b.settableReads==0)
        b.reset();b.input = .init(value:"raw" as NSString,supported:[],transactionAttributes:["AXValue"]);b.supported=["AXValue"]
        check("requested unsupported value skips capability rediscovery",!construction.construct(0).isSettable && b.supportedReads==0)
        b.reset();b.input = .init(role:"AXTextField",value:"prefix" as NSString,coverage:.init(count:30,availableRange:0..<6),supported:["AXTitle"],transactionAttributes:["AXValue"]);b.attributes["AXValue"]="changed" as NSString
        check("requested unsupported partial value avoids fresh native read",construction.construct(0).value=="prefix" && b.reads.isEmpty)
        b.reset();b.input = .init(value:date as NSDate,supported:["AXValue"],transactionAttributes:["AXDateTimeComponents"]);b.attributes["AXDateTimeComponents"]=NSNumber(value:224)
        check("requested unsupported date components use default without read",construction.construct(0).value=="formatted-2" && b.reads.isEmpty)
        b.reset();b.input = .init(role:"AXTextArea",value:large as NSString,supported:["AXValue"],transactionAttributes:["AXVisibleCharacterRange"]);b.attributes["AXVisibleCharacterRange"]=AXValueCreate(.cfRange,&nativeVisible)!
        check("requested unsupported visible range uses fallback without native query",construction.construct(0).truncationRange==NSRange(location:0,length:100000) && b.reads.isEmpty)
        b.reset();b.input = .init(value:"raw" as NSString,supported:["AXValue"],transactionAttributes:["AXValue"])
        check("requested supported value directly queries setter",construction.construct(0).isSettable && b.supportedReads==0 && b.settableReads==1)
        print("EVENT STREAM TRANSFORMED VALUES: \(checks) checks passed")
    }
}
