import Foundation
import ApplicationServices

struct EventStreamCaptureTreeCache<Element,Transaction,Monitor> {
    let tree:EventStreamCollectedTree<Element>
    let transaction:Transaction
    let invalidationMonitor:Monitor
}

struct EventStreamSelectionCaptureOutput<Revision> {
    let revision:Revision
    let webAreaURL:URL?
    let contextType:EventStreamElementContextType
    var screenshotNeededForContext:Bool
}

struct EventStreamParentSelection<Revision,Monitor> {
    let capture:EventStreamSelectionCaptureOutput<Revision>
    let invalidationMonitor:Monitor?
}

typealias EventStreamNativeCaptureTreeCache=EventStreamCaptureTreeCache<EventStreamAXNode,EventStreamNativeTreeTransaction,EventStreamTreeInvalidationMonitor>

struct EventStreamNativeSelectionWindow {
    let application:EventStreamAXNode
    let window:EventStreamAXNode
    let nativeWindow:EventStreamNativeWindow
}

struct EventStreamNativeSystemSelection {
    let applicationWindow:EventStreamNativeSelectionWindow
    let windowRevision:EventStreamNativeTreeRevision.Revision
    let invalidationMonitor:EventStreamTreeInvalidationMonitor?
    let url:URL?
    let contextType:EventStreamElementContextType
    let screenshotNeededForContext:Bool
}

@MainActor protocol EventStreamSelectionExtractorBackend {
    associatedtype Element
    associatedtype Identity:Hashable
    associatedtype Transaction
    associatedtype Monitor:AnyObject
    associatedtype Assertion:AnyObject
    associatedtype Revision
    func identity(_ element:Element)->Identity
    func enableAccessibility(application:Element,window:Element,type:EventStreamElementContextType)->Assertion?
    func disable(_ assertion:Assertion)
    func focusedElement(of application:Element)->Element?
    func makeMonitor(application:Element)->Monitor
    func isWebShaped(_ application:Element)->Bool
    func subtreeTransaction(root:Element,maximumChildCount:Int)->Transaction
    func makeContext(type:EventStreamElementContextType,application:Element,window:Element)->EventStreamMacTransformationContext
    func perform<Result>(_ transaction:Transaction,work:()throws->Result) rethrows->Result
    func capture(root:Element,window:Element,application:Element,focusedElement:Element?,
                 cachedTree:EventStreamCollectedTree<Element>?,previous:Revision?,
                 context:inout EventStreamMacTransformationContext,alwaysIncludeScreenshot:Bool,
                 enableAXDiffing:Bool)throws->EventStreamSelectionCaptureOutput<Revision>
}

@MainActor enum EventStreamSelectionExtractor {
    // Parent0x100242C78; common capture and display phases remain its callee.
    static func extract<Backend:EventStreamSelectionExtractorBackend>(
        application:Backend.Element,window:Backend.Element,focusedElement:Backend.Element?,
        type:EventStreamElementContextType,
        cache:EventStreamCaptureTreeCache<Backend.Element,Backend.Transaction,Backend.Monitor>?=nil,
        previous:Backend.Revision?=nil,rootOverride:Backend.Element?=nil,
        performAccessibilityEnablement:Bool,alwaysIncludeScreenshot:Bool=false,
        enableAXDiffing:Bool=true,backend:Backend
    )throws->EventStreamParentSelection<Backend.Revision,Backend.Monitor> {
        let root=rootOverride ?? window
        let assertion=performAccessibilityEnablement ? backend.enableAccessibility(application:application,window:window,type:type):nil
        defer {if let assertion {backend.disable(assertion)}}
        let focus=assertion != nil ? backend.focusedElement(of:application):focusedElement
        let accepted=cache.flatMap {cache in
            cache.tree.roots.first.map {backend.identity($0.node.element)==backend.identity(root)} == true ? cache:nil
        }
        let monitor=type == .fullUIContext ? accepted?.invalidationMonitor ?? backend.makeMonitor(application:application):nil
        let webShaped=backend.isWebShaped(application)
        let transaction=accepted?.transaction ?? backend.subtreeTransaction(root:root,
            maximumChildCount:type == .eventStreamContext && webShaped ? 20:100)
        var context=backend.makeContext(type:type,application:application,window:window)
        var capture=try backend.perform(transaction) {
            try backend.capture(root:root,window:window,application:application,focusedElement:focus,
                cachedTree:accepted?.tree,previous:previous,context:&context,
                alwaysIncludeScreenshot:alwaysIncludeScreenshot,enableAXDiffing:enableAXDiffing)
        }
        if webShaped,let url=capture.webAreaURL,shouldUseFullAppSnapshot(for:url) {capture.screenshotNeededForContext=true}
        return .init(capture:capture,invalidationMonitor:monitor)
    }
    //0x10024A198 checks only URL.host with Swift Regex.firstMatch.
    private static let fullAppSnapshotHost=try? Regex("(?i)(?:^|\\.)docs\\.google\\.[a-z.]+$")
    static func shouldUseFullAppSnapshot(for url:URL)->Bool {
        guard let host=url.host,let regex=fullAppSnapshotHost else {return false}
        return (try? regex.firstMatch(in:host)) != nil
    }
}

@MainActor struct EventStreamNativeSelectionExtractorBackend<Assertion:AnyObject>:EventStreamSelectionExtractorBackend {
    typealias Element=EventStreamAXNode
    typealias Identity=EventStreamSnapshotAXIdentity
    typealias Transaction=EventStreamNativeTreeTransaction
    typealias Monitor=EventStreamTreeInvalidationMonitor
    typealias Revision=EventStreamNativeTreeRevision.Revision
    private let acquire:(Element,Element,EventStreamElementContextType)->Assertion?
    private let release:(Assertion)->Void
    private let snapshots:EventStreamNativeSnapshots
    private let transactions:EventStreamNativeTransactions
    private let source:EventStreamNativeRawCaptureBackend
    private let traits:EventStreamNativeTransformationContextBackend
    private let monitorIO:EventStreamInvalidationMonitorIO
    // Native enablement acquisition/restoration is an explicit dependency.
    // It is never silently replaced with an always-nil implementation.
    init(enableAccessibility:@escaping (Element,Element,EventStreamElementContextType)->Assertion?,
         disable:@escaping (Assertion)->Void,snapshots:EventStreamNativeSnapshots?=nil,
         transactions:EventStreamNativeTransactions?=nil,source:EventStreamNativeRawCaptureBackend?=nil,
         traits:EventStreamNativeTransformationContextBackend?=nil,
         monitorIO:EventStreamInvalidationMonitorIO = .native) {
        let reader=snapshots ?? .init();self.snapshots=reader
        self.acquire=enableAccessibility;self.release=disable
        self.transactions=transactions ?? .init(snapshots:reader)
        self.source=source ?? .init(snapshots:reader);self.traits=traits ?? .init();self.monitorIO=monitorIO
    }
    func identity(_ element:Element)->Identity {.init(element:element.element)}
    func enableAccessibility(application:Element,window:Element,type:EventStreamElementContextType)->Assertion? {acquire(application,window,type)}
    func disable(_ assertion:Assertion) {release(assertion)}
    func focusedElement(of application:Element)->Element? {
        func decode(_ raw:AnyObject)->Element? {
            guard CFGetTypeID(raw)==AXUIElementGetTypeID() else {return nil}
            return application.relatedNode(unsafeBitCast(raw,to:AXUIElement.self))
        }
        if let raw=application.cachedAttribute("AXFocusedUIElement"),let focus=decode(raw) {return focus}
        guard application.mayReadAttribute("AXFocusedUIElement"),let raw=source.io.attribute(application.element,"AXFocusedUIElement") else {return nil}
        return decode(raw)
    }
    func makeMonitor(application:Element)->Monitor {.init(application:application.element,io:monitorIO)}
    func isWebShaped(_ application:Element)->Bool {traits.isWebShaped(application)}
    func subtreeTransaction(root:Element,maximumChildCount:Int)->Transaction {transactions.capture(root.element,maximumChildCount:maximumChildCount)}
    func makeContext(type:EventStreamElementContextType,application:Element,window:Element)->EventStreamMacTransformationContext {
        EventStreamNativeTransformationContext.make(type:type,application:application,window:window,backend:traits)
    }
    func perform<Result>(_ transaction:Transaction,work:()throws->Result) rethrows->Result {
        try EventStreamTreeTransactions.$current.withValue(transaction,operation:work)
    }
    func capture(root:Element,window:Element,application:Element,focusedElement:Element?,
                 cachedTree:EventStreamCollectedTree<Element>?,previous:Revision?,
                 context:inout EventStreamMacTransformationContext,alwaysIncludeScreenshot:Bool,
                 enableAXDiffing:Bool)throws->EventStreamSelectionCaptureOutput<Revision> {
        let result=try EventStreamNativeCaptureCore.capture(root:root,window:window,application:application,
            focusedElement:focusedElement,cachedTree:cachedTree,previous:previous,context:&context,
            alwaysIncludeScreenshot:alwaysIncludeScreenshot,enableAXDiffing:enableAXDiffing,backend:source)
        return .init(revision:result.revision,webAreaURL:result.webAreaURL,contextType:result.contextType,
            screenshotNeededForContext:result.screenshotNeededForContext)
    }
}

@MainActor enum EventStreamNativeSelectionExtractor {
    static func extract<Assertion:AnyObject>(
        from source:EventStreamCaptureContext<EventStreamAXNode>,type:EventStreamElementContextType,
        cache:EventStreamNativeCaptureTreeCache?=nil,previous:EventStreamNativeTreeRevision.Revision?=nil,
        rootOverride:EventStreamAXNode?=nil,performAccessibilityEnablement:Bool,
        alwaysIncludeScreenshot:Bool=false,enableAXDiffing:Bool=true,
        backend:EventStreamNativeSelectionExtractorBackend<Assertion>
    )throws->EventStreamNativeSystemSelection {
        let result=try EventStreamSelectionExtractor.extract(application:source.application,window:source.window,
            focusedElement:source.focusedElement,type:type,cache:cache,previous:previous,rootOverride:rootOverride,
            performAccessibilityEnablement:performAccessibilityEnablement,alwaysIncludeScreenshot:alwaysIncludeScreenshot,
            enableAXDiffing:enableAXDiffing,backend:backend)
        return .init(applicationWindow:.init(application:source.application,window:source.window,nativeWindow:source.nativeWindow),
            windowRevision:result.capture.revision,invalidationMonitor:result.invalidationMonitor,url:result.capture.webAreaURL,
            contextType:result.capture.contextType,screenshotNeededForContext:result.capture.screenshotNeededForContext)
    }
}
