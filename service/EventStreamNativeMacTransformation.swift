import Foundation
import AppKit
import ApplicationServices

@MainActor struct EventStreamNativeMacTransformationBackend:EventStreamMacTransformationBackend {
    typealias Element=EventStreamAXNode
    typealias Identity=EventStreamSnapshotAXIdentity
    private let titles:EventStreamNativeTitleAssociationBackend
    private let read:(Element,String)->AnyObject?
    private let processID:(Element)->pid_t?
    private let bundleIdentifier:(pid_t)->String?
    init(titles:EventStreamNativeTitleAssociationBackend?=nil,
         read:((Element,String)->AnyObject?)?=nil,processID:((Element)->pid_t?)?=nil,
         bundleIdentifier:((pid_t)->String?)?=nil) {
        self.titles=titles ?? .init()
        self.read=read ?? {node,name in
            var value:CFTypeRef?
            let status=AXUIElementCopyAttributeValue(node.element,name as CFString,&value)
            return [AXError.success,.noValue,.attributeUnsupported].contains(status) ? value:nil
        }
        // The PID getter first consults a hosted bridge. A bridge
        // owner must supply that resolver here; the default is the ordinary
        // native AX path. Hosted resolution/driver binding remains pending.
        self.processID=processID ?? {node in
            var pid:pid_t = -1
            return AXUIElementGetPid(node.element,&pid) == .success ? pid:nil
        }
        self.bundleIdentifier=bundleIdentifier ?? {NSRunningApplication(processIdentifier:$0)?.bundleIdentifier}
    }
    func identity(_ element:Element) -> Identity {titles.identity(element)}
    func titleTargets(_ element:Element) -> [Identity] {titles.titleTargets(element)}
    func title(for identity:Identity) -> String? {titles.title(for:identity)}
    func hasScrollBar(_ axis:EventStreamScrollAxis,of element:Element) -> Bool {
        let attribute=axis == .horizontal ? "AXHorizontalScrollBar":"AXVerticalScrollBar"
        // Typed cached value first, then uncached typed read.
        // An advertised attribute or an invalid cached value is not a bar.
        if let cached=element.cachedAttribute(attribute),CFGetTypeID(cached)==AXUIElementGetTypeID() {return true}
        guard element.mayReadAttribute(attribute),let value=read(element,attribute) else {return false}
        return CFGetTypeID(value)==AXUIElementGetTypeID()
    }
    func applicationBundleIdentifier(of element:Element) -> String? {
        guard let pid=processID(element) else {return nil}
        return bundleIdentifier(pid)
    }
}
