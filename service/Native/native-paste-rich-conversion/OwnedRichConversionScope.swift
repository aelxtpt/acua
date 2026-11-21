import AppKit
import Foundation
import ObjectiveC

private final class OwnedRichPasteboardState: @unchecked Sendable {
    let board = NSPasteboard.withUniqueName()
    private let lock = NSLock()
    private var getters = 0
    func get() -> NSPasteboard { lock.withLock { getters += 1 }; return board }
    var count: Int { lock.withLock { getters } }
}
private final class OwnedRichResourceState: @unchecked Sendable {
    private let lock = NSLock(); private var requests: [String] = []
    func add(_ request: AnyObject?) { lock.withLock { requests.append((request as? NSURLRequest)?.url?.absoluteString ?? "nil") } }
    var urls: [String] { lock.withLock { requests } }
}

///Own-process test harness only. AppKit initialization itself may request the
///general-pasteboard handle; substitute an owned namespace before initializing
///NSApplication or HTML importing. The real getter is never invoked here.
@MainActor final class OwnedRichConversionScope {
    private let pasteboard = OwnedRichPasteboardState()
    private let resources = OwnedRichResourceState()
    private let generalMethod: Method
    private let previousGeneral: IMP
    private let generalReplacement: IMP
    private let resourceMethod: Method
    private let previousResource: IMP
    private let resourceReplacement: IMP
    private var finished = false
    init() {
        let pb = pasteboard, resourceLog = resources
        generalMethod = class_getClassMethod(NSPasteboard.self,NSSelectorFromString("generalPasteboard"))!
        let getter: @convention(block) (AnyObject) -> NSPasteboard = { _ in pb.get() }
        generalReplacement = imp_implementationWithBlock(getter)
        previousGeneral = method_setImplementation(generalMethod,generalReplacement)
        resourceMethod = class_getInstanceMethod(ControllerPasteResourceLoadBlocker.self,
            NSSelectorFromString("webView:resource:willSendRequest:redirectResponse:fromDataSource:"))!
        let blocker: @convention(block) (AnyObject,AnyObject?,AnyObject?,AnyObject?,AnyObject?,AnyObject?) -> AnyObject? = { _,_,_,request,_,_ in
            resourceLog.add(request); return nil
        }
        resourceReplacement = imp_implementationWithBlock(blocker)
        previousResource = method_setImplementation(resourceMethod,resourceReplacement)
    }
    var generalGetterCalls: Int { pasteboard.count }
    var blockedResources: [String] { resources.urls }
    var ownedName: String { pasteboard.board.name.rawValue }
    func finish() {
        guard !finished else { return }; finished = true
        method_setImplementation(resourceMethod,previousResource); imp_removeBlock(resourceReplacement)
        method_setImplementation(generalMethod,previousGeneral); imp_removeBlock(generalReplacement)
        pasteboard.board.releaseGlobally()
    }
}
