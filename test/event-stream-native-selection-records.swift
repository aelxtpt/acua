import Foundation
import ApplicationServices

@main enum Tests {
    @MainActor static func main() throws {
        var checks=0
        func check(_ label:String,_ value:Bool) {
            precondition(value,"FAIL: \(label)");checks += 1;print("PASS: \(label)")
        }
        let root=AXUIElementCreateApplication(40000),child1=AXUIElementCreateApplication(40001),child2=AXUIElementCreateApplication(40002)
        func axRange(_ location:Int,_ length:Int)->AXValue {
            var range=CFRange(location:location,length:length);return AXValueCreate(.cfRange,&range)!
        }
        var trace:[String]=[],attributeStatus=AXError.success,attributeValue:AnyObject?=axRange(8,2)
        var countStatus=AXError.success,total=100,valueStatus=AXError.success,arrayValue:AnyObject?=[child1,child2] as NSArray
        var appExists=true,appName:String?="Application",appBundle:String?="com.example.app",pid:Int32=7,securePID:Int?=7
        var pidSequence:[Int32]=[]
        let marker=NSObject()
        var markerValue:AnyObject?,markerStatus=AXError.success,parameterizedStatus=AXError.success,parameterizedValue:AnyObject?
        let io=EventStreamNativeSelectionRecordIO(attribute:{element,name in
            precondition(CFEqual(element,root),"native attribute reference changed");trace.append("attribute:\(name)")
            if name=="AXSelectedTextMarkerRange" {return (markerStatus,markerValue)}
            return (attributeStatus,attributeValue)
        },parameterized:{element,name,parameter in
            precondition(CFEqual(element,root) && parameter === marker,"native parameterized reference changed")
            trace.append("parameterized:\(name)");return (parameterizedStatus,parameterizedValue)
        },isMarkerRange:{$0 === marker},arrayCount:{element,name in
            precondition(CFEqual(element,root),"native count reference changed");trace.append("count:\(name)");return (countStatus,total)
        },arrayValues:{element,name,index,maximum in
            precondition(CFEqual(element,root),"native array reference changed");trace.append("array:\(name):\(index):\(maximum)");return (valueStatus,arrayValue)
        },runningApplication:{element in
            precondition(CFEqual(element,root),"native application reference changed");trace.append("application")
            guard appExists else {return nil}
            return .init(name:{trace.append("name");return appName},processIdentifier:{trace.append("pid");return pidSequence.isEmpty ? pid:pidSequence.removeFirst()},bundleIdentifier:{trace.append("bundle");return appBundle})
        },secureInputPID:{trace.append("secure");return securePID})
        let backend=EventStreamNativeSelectionRecordBackend(io:io)
        func node(attributes:[String:AnyObject]=[:],supported:Set<String>?=nil,requested:Set<String>?=nil,
                  partial:[String:EventStreamPartialValue]=[:],related:((AXUIElement)->EventStreamAXNode)?=nil)->EventStreamAXNode {
            .init(root,supportedAttributes:supported,attributes:attributes,transactionAttributes:requested,
                  partialValues:partial,related:related,attributeReader:{_ in fatalError("native backend must use its explicit I/O without mutating snapshot")})
        }
        let cached=node(attributes:["AXSelectedTextRange":axRange(2,4)])
        check("cached typed range wins without native reads",backend.selectedRange(cached) == .init(location:2,length:4) && trace.isEmpty)
        let badRange=node(attributes:["AXSelectedTextRange":"bad" as NSString])
        check("malformed cached range falls back to fresh typed value",backend.selectedRange(badRange) == .init(location:8,length:2))
        check("range fallback leaves malformed source snapshot intact",badRange.cachedAttribute("AXSelectedTextRange") as? String == "bad")
        trace=[];_=backend.selectedRange(badRange)
        check("fresh range fallback is not written into source cache",trace==["attribute:AXSelectedTextRange"])
        let blocked=node(supported:["AXRole"])
        trace=[];check("known unsupported range skips fresh provider",backend.selectedRange(blocked)==nil && trace.isEmpty)
        let cachedUnsupported=node(attributes:["AXSelectedTextRange":axRange(3,1)],supported:["AXRole"])
        check("valid cached range precedes unsupported metadata",backend.selectedRange(cachedUnsupported) == .init(location:3,length:1) && trace.isEmpty)
        let unrequested=node(supported:["AXRole"],requested:["AXRole"])
        check("attribute outside prefetch request may read fresh range",backend.selectedRange(unrequested) == .init(location:8,length:2))
        trace=[]
        let requested=node(supported:["AXRole"],requested:["AXSelectedTextRange"])
        check("requested but unsupported range stays gated",backend.selectedRange(requested)==nil && trace.isEmpty)
        attributeValue=axRange(-3,1)
        check("native selected range preserves signed location",backend.selectedRange(node()) == .init(location:-3,length:1))
        attributeValue=axRange(0,0)
        check("native getter returns empty range for builder classification",backend.selectedRange(node()) == .init(location:0,length:0))
        var point=CGPoint(x:2,y:3);attributeValue=AXValueCreate(.cgPoint,&point)
        check("wrong AXValue type is not decoded as range",backend.selectedRange(node())==nil)
        attributeValue="not a range" as NSString
        check("wrong fresh attribute object becomes no range",backend.selectedRange(node())==nil)
        attributeValue="fresh text" as NSString;trace=[]
        let textCached=node(attributes:["AXSelectedText":"cached" as NSString])
        check("cached selected text wins",backend.selectedText(textCached)=="cached" && trace.isEmpty)
        check("cached empty selected text without marker fallback becomes nil",backend.selectedText(node(attributes:["AXSelectedText":"" as NSString]))==nil)
        check("wrong cached selected text reads fresh String",backend.selectedText(node(attributes:["AXSelectedText":NSNumber(value:1)]))=="fresh text")
        attributeStatus = .invalidUIElement
        check("nonignored fresh status discards a returned selected text value",backend.selectedText(node())==nil)
        attributeStatus = .noValue
        check("ignored noValue status retains returned text object",backend.selectedText(node())=="fresh text")
        attributeStatus = .attributeUnsupported
        check("ignored unsupported status retains returned text object",backend.selectedText(node())=="fresh text")
        attributeStatus = .success;attributeValue=nil
        check("successful missing selected text remains nil",backend.selectedText(node())==nil)
        markerValue=marker;parameterizedValue="marker text" as NSString;trace=[]
        let cachedMarker=node(attributes:["AXSelectedText":"" as NSString,"AXSelectedTextMarkerRange":marker],supported:["AXRole"])
        check("empty direct text uses cached marker despite unsupported metadata",backend.selectedText(cachedMarker)=="marker text" && trace==["parameterized:AXStringForTextMarkerRange"])
        trace=[]
        check("missing direct text reads marker then parameterized text",backend.selectedText(node())=="marker text" && trace==["attribute:AXSelectedText","attribute:AXSelectedTextMarkerRange","parameterized:AXStringForTextMarkerRange"])
        trace=[];attributeValue="direct wins" as NSString
        check("nonempty direct text skips marker and parameterized providers",backend.selectedText(node())=="direct wins" && trace==["attribute:AXSelectedText"])
        attributeValue=nil;trace=[]
        let malformedMarker=node(attributes:["AXSelectedTextMarkerRange":NSNumber(value:1)])
        check("malformed cached marker falls back to fresh typed marker",backend.selectedText(malformedMarker)=="marker text" && trace.contains("attribute:AXSelectedTextMarkerRange"))
        check("fresh marker fallback does not overwrite malformed cache",malformedMarker.cachedAttribute("AXSelectedTextMarkerRange") as? Int == 1)
        markerValue=NSNumber(value:1);trace=[]
        check("wrong fresh marker type skips parameterized operation",backend.selectedText(node())==nil && !trace.contains(where:{$0.hasPrefix("parameterized:")}))
        markerValue=marker;markerStatus = .noValue
        check("ignored marker attribute error retains a valid returned range",backend.selectedText(node())=="marker text")
        markerStatus = .success;parameterizedStatus = .noValue
        check("parameterized noValue discards returned string",backend.selectedText(cachedMarker)==nil)
        parameterizedStatus = .attributeUnsupported
        check("parameterized unsupported discards returned string",backend.selectedText(cachedMarker)==nil)
        parameterizedStatus = .cannotComplete
        check("parameterized failure discards returned string",backend.selectedText(cachedMarker)==nil)
        parameterizedStatus = .success;parameterizedValue="" as NSString
        check("empty marker-derived text becomes nil",backend.selectedText(cachedMarker)==nil)
        parameterizedValue=NSNumber(value:1)
        check("nonstring marker-derived value becomes nil",backend.selectedText(cachedMarker)==nil)
        parameterizedValue=" \n " as NSString
        check("whitespace marker-derived text is preserved",backend.selectedText(cachedMarker)==" \n ")
        trace=[]
        check("known unsupported marker skips native marker and parameterized reads",backend.selectedText(node(supported:["AXSelectedText"]))==nil && trace==["attribute:AXSelectedText"])
        markerValue=nil;parameterizedValue=nil
        let arrayCached=node(attributes:["AXSelectedRows":([child1,child2] as NSArray)])
        trace=[]
        let selected=try backend.selectedItems(arrayCached,attribute:"AXSelectedRows",maximum:1)
        check("cached selected array bypasses fresh maximum",selected?.count==2 && trace.isEmpty)
        check("cached selected array preserves order and native identity",selected.map {CFEqual($0[0].element,child1) && CFEqual($0[1].element,child2)}==true)
        let malformedCached=node(attributes:["AXSelectedRows":"bad" as NSString])
        check("present nonarray cache returns nil without fresh fallback",try backend.selectedItems(malformedCached,attribute:"AXSelectedRows",maximum:12)==nil && trace.isEmpty)
        let nullCached=node(attributes:["AXSelectedRows":NSNull()])
        check("cached null array is authoritative without fresh fallback",try backend.selectedItems(nullCached,attribute:"AXSelectedRows",maximum:12)==nil && trace.isEmpty)
        let partial=EventStreamPartialValue(value:[child2] as NSArray,array:.init(count:200,availableRanges:[0..<1]),string:nil)
        let partialNode=node(supported:["AXRole"],partial:["AXSelectedRows":partial])
        let partialResult=try backend.selectedItems(partialNode,attribute:"AXSelectedRows",maximum:12)
        check("cached partial payload wins even when unsupported",partialResult?.count==1 && CFEqual(partialResult![0].element,child2) && trace.isEmpty)
        let invalidMembers=node(attributes:["AXSelectedRows":[NSNull(),child1,"bad" as NSString,child2,NSNumber(value:4)] as NSArray])
        let compacted=try backend.selectedItems(invalidMembers,attribute:"AXSelectedRows",maximum:12)
        check("malformed cached array members are individually omitted",compacted?.count==2 && CFEqual(compacted![0].element,child1) && CFEqual(compacted![1].element,child2))
        let relatedChild=EventStreamAXNode(child1,supportedAttributes:[],attributes:["AXTitle":"related" as NSString])
        let related=node(attributes:["AXSelectedRows":[child1] as NSArray],related:{_ in relatedChild})
        check("decoded references preserve source related-node owner",try backend.selectedItems(related,attribute:"AXSelectedRows",maximum:12)?.first === relatedChild)
        trace=[];check("known unsupported fresh array does not query count",try backend.selectedItems(blocked,attribute:"AXSelectedRows",maximum:12)==nil && trace.isEmpty)
        trace=[];total=0
        let fresh=node()
        check("zero count still performs bounded copy and retains returned references",try backend.selectedItems(fresh,attribute:"AXSelectedRows",maximum:12)?.count==2)
        check("array ABI uses attribute index 0 and the requested maximum",trace==["count:AXSelectedRows","array:AXSelectedRows:0:12"])
        check("fresh array does not alter source attributes",fresh.cachedAttributesSnapshot().isEmpty)
        trace=[];total=200
        _=try backend.selectedItems(node(),attribute:"AXSelectedCells",maximum:12)
        check("large count does not replace copy maximum",trace==["count:AXSelectedCells","array:AXSelectedCells:0:12"])
        countStatus = .noValue;trace=[]
        check("ignored count error returns nil without copy",try backend.selectedItems(node(),attribute:"AXSelectedRows",maximum:12)==nil && trace==["count:AXSelectedRows"])
        countStatus = .attributeUnsupported;trace=[]
        check("unsupported count is tolerated without copy",try backend.selectedItems(node(),attribute:"AXSelectedRows",maximum:12)==nil && trace==["count:AXSelectedRows"])
        countStatus = .invalidUIElement
        do {_=try backend.selectedItems(node(),attribute:"AXSelectedRows",maximum:12);preconditionFailure("expected count failure")}
        catch let error as EventStreamNativeSelectionRecordBackend.Failure {check("nonignored count status propagates exact AX failure",error.status == .invalidUIElement)}
        countStatus = .success;valueStatus = .noValue
        check("ignored copy error can still return an array",try backend.selectedItems(node(),attribute:"AXSelectedRows",maximum:12)?.count==2)
        valueStatus = .attributeUnsupported
        check("unsupported copy retains a present native array",try backend.selectedItems(node(),attribute:"AXSelectedRows",maximum:12)?.count==2)
        valueStatus = .cannotComplete
        do {_=try backend.selectedItems(node(),attribute:"AXSelectedRows",maximum:12);preconditionFailure("expected copy failure")}
        catch let error as EventStreamNativeSelectionRecordBackend.Failure {check("nonignored copy error throws despite present array",error.status == .cannotComplete)}
        valueStatus = .success;arrayValue=nil
        check("successful missing array stays nil",try backend.selectedItems(node(),attribute:"AXSelectedRows",maximum:12)==nil)
        arrayValue="bad" as NSString
        check("successful nonarray fresh payload stays nil",try backend.selectedItems(node(),attribute:"AXSelectedRows",maximum:12)==nil)
        appExists=false;trace=[]
        check("missing running app stops metadata extraction",backend.application(node())==nil && trace==["application"])
        appExists=true;appName=nil;trace=[]
        check("missing app name skips PID secure input and bundle",backend.application(node())==nil && trace==["application","name"])
        appName="";trace=[]
        check("empty app name skips remaining metadata",backend.application(node())==nil && trace==["application","name"])
        appName=" \n ";trace=[]
        let application=backend.application(node())
        check("metadata samples one app object in getter order",trace==["application","name","pid","secure","pid","bundle"])
        check("named application preserves fields and whitespace",application == .init(name:" \n ",secureInput:true,processIdentifier:7,bundleIdentifier:"com.example.app"))
        appName="Application";pidSequence=[7,8]
        check("secure input and emitted PID use separate reads of same app object",backend.application(node()) == .init(name:"Application",secureInput:true,processIdentifier:8,bundleIdentifier:"com.example.app"))
        securePID=nil
        check("missing secure input PID is false",backend.application(node())?.secureInput==false)
        securePID=9
        check("another secure input owner is false",backend.application(node())?.secureInput==false)
        pid = -2;securePID = -2
        check("application helper adds no positive PID guard",backend.application(node())?.secureInput==true && backend.application(node())?.processIdentifier == -2)
        appBundle=""
        check("empty app bundle becomes nil",backend.application(node())?.bundleIdentifier==nil)
        appBundle=" \t "
        check("whitespace app bundle is preserved",backend.application(node())?.bundleIdentifier==" \t ")
        let description=EventStreamAXNotificationDescription.describe("AXSelectedTextChanged")
        check("notification reflection uses the nominal type and field name",description=="AXNotification(name: AXSelectedTextChanged)")
        check("item notification description uses same runtime representation",EventStreamAXNotificationDescription.describe("AXSelectedRowsChanged")=="AXNotification(name: AXSelectedRowsChanged)")
        check("unknown raw notification name retains same wrapper representation",EventStreamAXNotificationDescription.describe("other")=="AXNotification(name: other)")
        appName="Application";appBundle="com.example.app";pid=7;securePID=7;pidSequence=[];trace=[]
        let rowAttributes:[String:AnyObject]=["AXRole":"AXRow" as NSString,"AXTitle":"  row label  " as NSString,"AXValue":"row value" as NSString]
        let row=EventStreamAXNode(child1,supportedAttributes:Set(rowAttributes.keys),attributes:rowAttributes,attributeReader:{_ in preconditionFailure("unexpected fresh row descriptor read")})
        let attributes:[String:AnyObject]=[
            "AXRole":"AXTextArea" as NSString,"AXSubrole":"" as NSString,
            "AXTitle":"  raw title  " as NSString,"AXDescription":"description" as NSString,
            "AXValue":"target value" as NSString,"AXNumberOfCharacters":NSNumber(value:12),
            "AXPlaceholderValue":"placeholder" as NSString,"AXIdentifier":"factory-target" as NSString,
            "AXWindow":NSNull(),"AXParent":NSNull(),"AXSelectedText":"cached text" as NSString,
            "AXSelectedTextRange":axRange(2,3),"AXSelectedRows":[child1] as NSArray]
        let source=EventStreamAXNode(root,supportedAttributes:Set(attributes.keys),attributes:attributes,
            related:{_ in row},attributeReader:{_ in preconditionFailure("unexpected fresh factory source read")})
        let context=EventStreamNativeContext();var identity=110
        let factory=context.makeSelectionRecordBuilder(nextIdentity:{identity += 1;return .init(id:identity,timestamp:Date(timeIntervalSince1970:20))},selectionBackend:backend)
        let factoryText=factory.make(element:source,notification:"AXSelectedTextChanged")!
        check("native factory connects selected text range and application provider",factoryText.record.selection?.selectedText=="cached text" && factoryText.record.selection?.selectedRange == .init(location:2,length:3) && factoryText.record.app?.processIdentifier==7)
        check("native factory target keeps raw title whitespace",factoryText.record.selection?.target?.title=="  raw title  ")
        check("native factory descriptor and secure-input metadata remain captured",factoryText.record.selection?.target?.value=="target value" && factoryText.record.app?.secureInput==true)
        check("native factory does not invent a containing window",factoryText.record.window==nil)
        check("native factory supplies reflected grouping key without custom descriptor callback",factoryText.key=="Application||AXNotification(name: AXSelectedTextChanged)")
        let factoryRows=factory.make(element:source,notification:"AXSelectedRowsChanged")!
        check("native factory item projection uses derived title policy",factoryRows.record.selection?.selectedItems.first?.title=="row label" && factoryRows.record.selection?.selectedItems.first?.value=="row value")
        check("native factory item key contains actual cached target identifier",factoryRows.key.contains("|factory-target|  raw title  |"))
        check("native factory shares caller identity source and bypasses fresh array for cache",factoryText.record.id==111 && factoryRows.record.id==112 && !trace.contains(where:{$0.hasPrefix("array:") || $0.hasPrefix("count:")}))
        // Real snapshot construction uses a supplied TaskLocal table; all raw
        // references below have invalid negative PIDs and cannot name another
        // application's UI. No callback-source preparation is injected.
        let callbackRoot=AXUIElementCreateApplication(-41000),callbackWindow=AXUIElementCreateApplication(-41001)
        let callbackApp=AXUIElementCreateApplication(-41002)
        let callbackRows=(0..<15).map {AXUIElementCreateApplication(pid_t(-42000-$0))}
        var table:[EventStreamSnapshotAXIdentity:[String:AnyObject]]=[:]
        let callbackAttributes:[String:AnyObject]=[
            "AXRole":"AXTable" as NSString,"AXSubrole":"" as NSString,
            "AXTitle":"  callback target  " as NSString,"AXDescription":"callback description" as NSString,
            "AXValue":"callback value" as NSString,"AXPlaceholderValue":"" as NSString,
            "AXIdentifier":"callback-table" as NSString,"AXWindow":callbackWindow,"AXParent":NSNull(),
            "AXChildren":[callbackRows[0],callbackRows[1]] as NSArray,
            "AXSelectedRows":callbackRows as NSArray,"AXSelectedTextRange":axRange(1,3),
            "AXSelectedText":"snapshot text" as NSString]
        table[.init(element:callbackRoot)]=callbackAttributes
        table[.init(element:callbackWindow)]=["AXRole":"AXWindow" as NSString,"AXTitle":"Snapshot Window" as NSString,"AXURL":URL(string:"https://snapshot.example/window")! as NSURL]
        table[.init(element:callbackApp)]=["AXRole":"AXApplication" as NSString,"AXTitle":"Snapshot Application" as NSString]
        for (index,element) in callbackRows.enumerated() {
            table[.init(element:element)]=["AXRole":"AXRow" as NSString,"AXTitle":"  snapshot row \(index)  " as NSString,"AXValue":"value \(index)" as NSString]
        }
        let constructorRequested=EventStreamSnapshotAttributes.common.union(["AXWindow","AXParent","AXChildren","AXSelectedRows","AXSelectedText","AXSelectedTextRange","AXValueDescription"])
        let transaction=EventStreamNativeTreeTransaction(root:callbackRoot,snapshots:.init(attributeTable:table,requestedAttributes:constructorRequested),partialValues:[:],roleFrequency:[:])
        var callbackIO=io
        callbackIO.attribute={_,_ in preconditionFailure("callback source lost a captured scalar")}
        callbackIO.arrayCount={_,_ in preconditionFailure("callback source lost captured selected rows")}
        callbackIO.arrayValues={_,_,_,_ in preconditionFailure("callback source must not replace cached rows with max12")}
        var callbackLookups=0
        callbackIO.runningApplication={element in
            precondition(CFEqual(element,callbackRoot));callbackLookups += 1
            return .init(name:{"Snapshot App"},processIdentifier:{-41000},bundleIdentifier:{"snapshot.bundle"})
        }
        callbackIO.secureInputPID={nil}
        var callbackSequence=900
        let owner=EventStreamNativeSelectionRecordFactory(nextIdentity:{callbackSequence += 1;return .init(id:callbackSequence,timestamp:Date(timeIntervalSince1970:30))},selectionBackend:.init(io:callbackIO))
        check("callback source owner rejects unrelated notifications without consuming identity",owner.make(element:callbackRoot,notification:"AXValueChanged")==nil && callbackSequence==900 && callbackLookups==0)
        let capturedURL=URL(string:"https://captured.example/shared")!
        owner.context.resolver.recordCapturedURL(capturedURL,for:77)
        let owned=EventStreamTreeTransactions.$current.withValue(transaction) {
            let root=owner.snapshots.node(callbackRoot)
            check("snapshot-aware context wraps application through current transaction",owner.context.backend.application(-41002).cachedAttribute("AXTitle") as? String == "Snapshot Application")
            let window=owner.context.backend.node(root,"AXWindow")
            check("snapshot-aware context wraps related window through transaction",window?.cachedAttribute("AXTitle") as? String == "Snapshot Window")
            let children=owner.context.backend.nodes(root,"AXChildren")
            check("snapshot-aware array wrappers retain captured child metadata",children.count==2 && children[0].cachedAttribute("AXTitle") as? String == "  snapshot row 0  " && children[1].cachedAttribute("AXTitle") as? String == "  snapshot row 1  ")
            let legacy=EventStreamNativeContextBackend().node(root,"AXWindow")
            check("existing context construction keeps its raw-node default",legacy?.cachedAttributesSnapshot().isEmpty==true)
            let rows=owner.make(element:callbackRoot,notification:"AXSelectedRowsChanged")!
            let text=owner.make(element:callbackRoot,notification:"AXSelectedTextChanged")!
            return (rows,text)
        }
        check("callback constructor preserves all15 cached rows above fresh max12",owned.0.record.selection?.selectedItems.count==15)
        check("callback constructor snapshots related selected item descriptions",owned.0.record.selection?.selectedItems.first?.title=="snapshot row 0" && owned.0.record.selection?.selectedItems.last?.title=="snapshot row 14")
        check("callback constructor retains raw target title policy",owned.0.record.selection?.target?.title=="  callback target  ")
        check("callback constructor uses captured containing-window title and URL",owned.0.record.window?.title=="Snapshot Window" && owned.0.record.window?.url=="https://snapshot.example/window")
        check("callback constructor preserves application helper result",owned.0.record.app == EventStreamApp(name:"Snapshot App",secureInput:false,processIdentifier:-41000,bundleIdentifier:"snapshot.bundle"))
        check("callback text route retains captured selected range and text",owned.1.record.selection?.selectedRange == EventStreamTextRange(location:1,length:3) && owned.1.record.selection?.selectedText=="snapshot text")
        check("callback constructor allocates identity only after complete extraction",owned.0.record.id==901 && owned.1.record.id==902 && callbackLookups==2)
        check("callback source factory uses the notification representation",owned.1.key=="Snapshot App|Snapshot Window|AXNotification(name: AXSelectedTextChanged)")
        check("callback construction restores caller TaskLocal transaction",EventStreamTreeTransactions.current==nil)
        check("callback source owner retains shared recorder URL cache",owner.context.resolver.windowURLs[77]==capturedURL)
        print("\(checks) checks")
    }
}
