import Foundation
import ApplicationServices

private final class ParentMonitor {var invalidated=false;let name:String;init(_ name:String) {self.name=name}}
private final class ParentAssertion {}
private final class ParentTransaction {let name:String;init(_ name:String) {self.name=name}}
@MainActor private final class ParentBackend:EventStreamSelectionExtractorBackend {
    typealias Element=Int
    typealias Identity=Int
    typealias Monitor=ParentMonitor
    typealias Assertion=ParentAssertion
    typealias Transaction=ParentTransaction
    typealias Revision=Int
    var events:[String]=[],budgets:[Int]=[]
    var assertion:Assertion?,updatedFocus:Int?,web=false,contextWeb=false
    var current:Transaction?,failure:Error?
    var commonURL:URL?,commonScreenshot=false,commonType:EventStreamElementContextType = .eventStreamContext
    var captured:(root:Int,window:Int,app:Int,focus:Int?,cache:EventStreamCollectedTree<Int>?,previous:Int?,force:Bool,diff:Bool,transaction:Transaction?,context:EventStreamMacTransformationContext)?
    var contextTransaction:Transaction?,newMonitors=0,newTransactions=0
    func identity(_ element:Int)->Int {element}
    func enableAccessibility(application:Int,window:Int,type:EventStreamElementContextType)->Assertion? {events.append("enable\(application):\(window):\(type.rawValue)");return assertion}
    func disable(_ assertion:Assertion) {events.append("disable")}
    func focusedElement(of application:Int)->Int? {events.append("focus\(application)");return updatedFocus}
    func makeMonitor(application:Int)->Monitor {events.append("monitor\(application)");newMonitors += 1;return .init("new")}
    func isWebShaped(_ application:Int)->Bool {events.append("web\(application)");return web}
    func subtreeTransaction(root:Int,maximumChildCount:Int)->Transaction {events.append("transaction\(root):\(maximumChildCount)");budgets.append(maximumChildCount);newTransactions += 1;return .init("new")}
    func makeContext(type:EventStreamElementContextType,application:Int,window:Int)->EventStreamMacTransformationContext {
        events.append("context\(type.rawValue)");contextTransaction=current
        return .init(type:type,isWebShaped:contextWeb,urlShortener:.init(configuration:.init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true)))
    }
    func perform<Result>(_ transaction:Transaction,work:()throws->Result) rethrows->Result {
        events.append("enter\(transaction.name)");let previous=current;current=transaction
        defer {current=previous;events.append("exit\(transaction.name)")}
        return try work()
    }
    func capture(root:Int,window:Int,application:Int,focusedElement:Int?,cachedTree:EventStreamCollectedTree<Int>?,previous:Int?,context:inout EventStreamMacTransformationContext,alwaysIncludeScreenshot:Bool,enableAXDiffing:Bool)throws->EventStreamSelectionCaptureOutput<Int> {
        events.append("capture");captured=(root,window,application,focusedElement,cachedTree,previous,alwaysIncludeScreenshot,enableAXDiffing,current,context)
        if let failure {throw failure}
        return .init(revision:123,webAreaURL:commonURL,contextType:commonType,screenshotNeededForContext:commonScreenshot)
    }
}

@main enum SelectionExtractorTests {
    enum Failure:Error {case capture}
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ result:@autoclosure()->Bool) {
        guard result() else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        typealias Tree=EventStreamCollectedTree<Int>
        typealias Cache=EventStreamCaptureTreeCache<Int,ParentTransaction,ParentMonitor>
        func tree(_ roots:[Int])->Tree {.init(roots:roots.map {.init(node:.init(element:$0),path:[],children:[],childrenSubset:nil)})}
        let backend=ParentBackend()
        func extract(type:EventStreamElementContextType = .fullUIContext,cache:Cache?=nil,root:Int?=nil,focus:Int?=7,enable:Bool=false,previous:Int?=nil,force:Bool=false,diff:Bool=true)throws->EventStreamParentSelection<Int,ParentMonitor> {
            try EventStreamSelectionExtractor.extract(application:9,window:42,focusedElement:focus,type:type,cache:cache,previous:previous,rootOverride:root,performAccessibilityEnablement:enable,alwaysIncludeScreenshot:force,enableAXDiffing:diff,backend:backend)
        }
        let first=try extract()
        check("fresh full capture acquires resources and scopes common capture in original order",backend.events==["monitor9","web9","transaction42:100","context0","enternew","capture","exitnew"])
        check("default root is window and independent supplied focus is retained",backend.captured?.root==42 && backend.captured?.window==42 && backend.captured?.app==9 && backend.captured?.focus==7)
        check("fresh parent uses no raw cache or predecessor",backend.captured?.cache==nil && backend.captured?.previous==nil)
        check("full parent returns its monitor and core revision",first.invalidationMonitor?.name=="new" && first.capture.revision==123)
        check("core output context type is forwarded rather than overwritten",first.capture.contextType == .eventStreamContext)
        check("transaction is restored on ordinary success",backend.current==nil && backend.captured?.transaction?.name=="new")
        let oldTransaction=ParentTransaction("cached"),oldMonitor=ParentMonitor("cached")
        let cache=Cache(tree:tree([42,777]),transaction:oldTransaction,invalidationMonitor:oldMonitor)
        backend.events=[];let reused=try extract(cache:cache)
        check("matching first root reuses raw tree transaction and monitor",backend.captured?.cache?.roots.map(\.node.element)==[42,777] && backend.captured?.transaction===oldTransaction && reused.invalidationMonitor===oldMonitor)
        check("accepted cache skips new monitor and subtree transaction",backend.events==["web9","context0","entercached","capture","exitcached"])
        oldMonitor.invalidated=true
        _=try extract(cache:cache)
        check("parent does not substitute its own monitor consumption policy",backend.captured?.transaction===oldTransaction && backend.captured?.cache != nil)
        backend.events=[];let wrong=try extract(cache:cache,root:77)
        check("explicit root mismatch invalidates whole cache payload",backend.captured?.root==77 && backend.captured?.cache==nil && backend.captured?.transaction !== oldTransaction && wrong.invalidationMonitor !== oldMonitor)
        check("explicit root never changes supplied window or focus",backend.captured?.window==42 && backend.captured?.focus==7)
        let empty=Cache(tree:tree([]),transaction:oldTransaction,invalidationMonitor:oldMonitor)
        _=try extract(cache:empty)
        check("empty raw forest cannot validate cached resources",backend.captured?.cache==nil && backend.captured?.transaction !== oldTransaction)
        let later=Cache(tree:tree([77,42]),transaction:oldTransaction,invalidationMonitor:oldMonitor)
        _=try extract(cache:later)
        check("matching a later root does not validate the first root",backend.captured?.cache==nil)
        backend.events=[];let event=try extract(type:.eventStreamContext,cache:cache)
        check("event capture retains cached tree transaction without a parent monitor",event.invalidationMonitor==nil && backend.captured?.transaction===oldTransaction && !backend.events.contains("monitor9"))
        backend.events=[];let info=try extract(type:.informationalContext,cache:cache)
        check("informational capture also omits the parent monitor",info.invalidationMonitor==nil && backend.captured?.cache != nil && !backend.events.contains("monitor9"))
        backend.web=true;backend.budgets=[]
        _=try extract(type:.eventStreamContext)
        _=try extract(type:.fullUIContext)
        _=try extract(type:.informationalContext)
        backend.web=false;_=try extract(type:.eventStreamContext)
        check("only event plus independently web-shaped uses20-child transaction",backend.budgets==[20,100,100,100])
        backend.events=[];backend.assertion=ParentAssertion();backend.updatedFocus=8
        _=try extract(enable:true)
        check("nonnull enablement refreshes focus before monitor and capture",backend.events.prefix(3)==["enable9:42:0","focus9","monitor9"] && backend.captured?.focus==8)
        check("successful enabled capture disables assertion after transaction exit",backend.events.suffix(2)==["exitnew","disable"] && backend.events.filter {$0=="disable"}.count==1)
        backend.updatedFocus=nil;_=try extract(enable:true)
        check("nil refreshed focus clears the earlier supplied focus",backend.captured?.focus==nil)
        backend.assertion=nil;backend.events=[];_=try extract(enable:true)
        check("nil enablement assertion preserves supplied focus and skips refresh cleanup",backend.captured?.focus==7 && !backend.events.contains("focus9") && !backend.events.contains("disable"))
        backend.assertion=ParentAssertion();backend.events=[];_=try extract(enable:false)
        check("disabled enablement never acquires refreshes or releases an assertion",!backend.events.contains {$0.hasPrefix("enable") || $0.hasPrefix("focus") || $0=="disable"})
        backend.events=[];backend.failure=Failure.capture
        do {_=try extract(enable:true);fatalError("must throw")} catch Failure.capture {}
        check("capture failure propagates and restores transaction before assertion cleanup",backend.events.suffix(2)==["exitnew","disable"] && backend.current==nil)
        backend.failure=CancellationError();backend.events=[]
        do {_=try extract(enable:true);fatalError("must cancel")} catch is CancellationError {}
        check("cancellation preserves error type and releases acquired assertion once",backend.events.suffix(2)==["exitnew","disable"] && backend.events.filter {$0=="disable"}.count==1)
        backend.failure=nil;backend.current=ParentTransaction("outer");let outer=backend.current
        _=try extract(cache:cache,previous:99,force:true,diff:false)
        check("context is constructed before entering parent transaction",backend.contextTransaction===outer && backend.captured?.transaction===oldTransaction)
        check("nested parent transaction restores caller transaction",backend.current===outer)
        check("predecessor and both capture flags are forwarded independently",backend.captured?.previous==99 && backend.captured?.force==true && backend.captured?.diff==false)
        backend.current=nil
        let docs=URL(string:"https://docs.google.com/document/d/123")!
        backend.commonURL=docs;backend.commonScreenshot=false;backend.web=true;backend.contextWeb=false
        let forced=try extract(type:.informationalContext)
        check("parent web sample forces full screenshot independently of later context flag",forced.capture.screenshotNeededForContext && backend.captured?.context.isWebShaped==false)
        backend.web=false
        let nonWeb=try extract()
        check("URL rule is gated by earlier parent web-shape sample",!nonWeb.capture.screenshotNeededForContext)
        backend.web=true;backend.commonURL=nil
        let noURL=try extract()
        check("missing captured URL does not force screenshot",!noURL.capture.screenshotNeededForContext)
        backend.commonURL=URL(string:"https://example.test/docs.google.com")
        let pathOnly=try extract()
        check("URL rule does not scan path for a docs host",!pathOnly.capture.screenshotNeededForContext)
        backend.commonScreenshot=true
        let preserved=try extract()
        check("nonmatching parent URL rule never clears a common screenshot result",preserved.capture.screenshotNeededForContext)
        for host in ["docs.google.com","sub.docs.google.com","DOCS.GOOGLE.COM","docs.google.co.uk","docs.google.com.evil","docs.google.."] {
            check("docs host rule accepts host \(host)",EventStreamSelectionExtractor.shouldUseFullAppSnapshot(for:URL(string:"https://\(host)")!))
        }
        for host in ["notdocs.google.com","docs-google.com","docs.google.com1","docs.google","docs.google.com.evil1","docs.google.com-example"] {
            check("docs host rule rejects host \(host)",!EventStreamSelectionExtractor.shouldUseFullAppSnapshot(for:URL(string:"https://\(host)")!))
        }
        check("hostless URL cannot force full screenshot",!EventStreamSelectionExtractor.shouldUseFullAppSnapshot(for:URL(string:"file:///docs.google.com")!))
        // Controlled AX values exercise the real native focus adapter. These
        // references do not read or operate any external application's UI.
        let appReference=AXUIElementCreateApplication(40000)
        let cachedFocus=EventStreamAXNode(AXUIElementCreateApplication(40001))
        let liveFocus=EventStreamAXNode(AXUIElementCreateApplication(40002))
        var freshFocus:AnyObject?=liveFocus.element,focusReads:[String]=[]
        let focusSource=EventStreamNativeRawCaptureBackend(io:.init(attribute:{_,name in
            focusReads.append(name);return freshFocus
        },bundleInfo:{_ in nil},isMarkerRange:{_ in false}))
        let native=EventStreamNativeSelectionExtractorBackend<NSObject>(enableAccessibility:{_,_,_ in fatalError("unused")},disable:{_ in fatalError("unused")},source:focusSource)
        func application(supported:Set<String>,requested:Set<String>?=nil,cached:AnyObject?=nil)->EventStreamAXNode {
            .init(appReference,supportedAttributes:supported,attributes:cached.map {["AXFocusedUIElement":$0]} ?? [:],
                transactionAttributes:requested,related:{CFEqual($0,cachedFocus.element) ? cachedFocus:liveFocus})
        }
        let cachedApplication=application(supported:["AXRole"],cached:cachedFocus.element)
        check("native typed cached focus wins outside advertised attributes",native.focusedElement(of:cachedApplication)===cachedFocus && focusReads.isEmpty)
        let malformed=application(supported:["AXFocusedUIElement"],cached:"malformed" as NSString)
        check("native malformed cached focus falls through to gated fresh read",native.focusedElement(of:malformed)===liveFocus && focusReads==["AXFocusedUIElement"])
        check("native fresh focus does not overwrite malformed source snapshot",malformed.cachedAttribute("AXFocusedUIElement") as? String == "malformed")
        focusReads=[]
        check("native advertised unsupported focus avoids fresh read",native.focusedElement(of:application(supported:["AXRole"]))==nil && focusReads.isEmpty)
        check("native requested unsupported focus avoids fresh read",native.focusedElement(of:application(supported:[],requested:["AXFocusedUIElement"]))==nil && focusReads.isEmpty)
        check("native focus outside requested set permits fresh read",native.focusedElement(of:application(supported:[],requested:["AXRole"]))===liveFocus && focusReads==["AXFocusedUIElement"])
        freshFocus="wrong live type" as NSString;focusReads=[]
        check("native wrong-type fresh focus is absent",native.focusedElement(of:application(supported:[]))==nil && focusReads==["AXFocusedUIElement"])
        freshFocus=nil;focusReads=[]
        check("native missing fresh focus is absent without manufacturing an element",native.focusedElement(of:application(supported:[]))==nil && focusReads==["AXFocusedUIElement"])
        print("EVENT STREAM PARENT SELECTION EXTRACTOR: \(checks) checks passed")
    }
}
