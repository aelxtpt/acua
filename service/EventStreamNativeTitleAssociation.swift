import Foundation
import ApplicationServices

@MainActor struct EventStreamNativeTitleAssociationBackend:EventStreamTitleAssociationBackend {
    typealias Element=EventStreamAXNode
    typealias Identity=EventStreamSnapshotAXIdentity
    private static let attribute="AXServesAsTitleForUIElements"
    private let read:(Element,String)->AnyObject?
    private let snapshots:EventStreamNativeSnapshots
    init(read:((Element,String)->AnyObject?)?=nil,snapshots:EventStreamNativeSnapshots?=nil) {
        self.snapshots=snapshots ?? .init()
        self.read=read ?? {node,name in
            var value:CFTypeRef?
            let error=AXUIElementCopyAttributeValue(node.element,name as CFString,&value)
            return [AXError.success,.noValue,.attributeUnsupported].contains(error) ? value:nil
        }
    }
    func identity(_ element:Element) -> Identity {.init(element:element.element)}
    // Native shared-transform callback0x1007654B0 collects the target under
    // the active TaskLocal transaction, then decodes only captured AXTitle.
    // It does not fall back to the edited item's title or a lazy title read.
    func title(for identity:Identity) -> String? {
        snapshots.capture(identity.element).attributes["AXTitle"] as? String
    }
    func titleTargets(_ element:Element) -> [Identity] {
        // 0x1007B7A4C: a valid captured array, including [], wins. Invalid
        // cached types fall back to a fresh read under requested/support gates.
        // Neither success nor failure of that read replaces the captured table.
        if let targets=decode(element.cachedAttribute(Self.attribute)) {return targets}
        guard element.mayReadAttribute(Self.attribute) else {return []}
        return decode(read(element,Self.attribute)) ?? []
    }
    private func decode(_ raw:AnyObject?) -> [Identity]? {
        guard let raw,CFGetTypeID(raw)==CFArrayGetTypeID(),let array=raw as? [AnyObject] else {return nil}
        // 0x10071E134 ->0x1006F4DF8 uses compactMap of the element
        // unwrapping operation: malformed members are discarded individually.
        return array.compactMap {value in
            guard CFGetTypeID(value)==AXUIElementGetTypeID() else {return nil}
            return .init(element:unsafeBitCast(value,to:AXUIElement.self))
        }
    }
}
