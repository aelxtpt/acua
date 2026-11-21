import ApplicationServices

extension SettingsAudioHeading where Element == EventStreamAXNode {
    /// Uses the existing node's snapshots/related-node factory, including its
    /// current transaction. No detached raw reader bypasses those values.
    @MainActor static func ax(application: @escaping (Int32) -> EventStreamAXNode,
                              isMacOS26OrLater: @escaping () -> Bool) -> Self {
        .init(environment:.init(focusedWindow:{ pid in
            let root=application(pid)
            guard let raw=root.attribute("AXFocusedWindow"),CFGetTypeID(raw)==AXUIElementGetTypeID() else { return nil }
            return root.relatedNode(unsafeDowncast(raw,to:AXUIElement.self))
        },sections:{ window in
            guard let rows=window.attribute("AXSections") as? [[String:Any]] else { return [] }
            return rows.compactMap { row in
                guard let id=row["SectionUniqueID"] as? String,let raw=row["SectionObject"] as AnyObject?,
                      CFGetTypeID(raw)==AXUIElementGetTypeID() else { return nil }
                return .init(identifier:id,element:window.relatedNode(unsafeDowncast(raw,to:AXUIElement.self)))
            }
        },children:{ EventStreamNativeChildren(parent:$0).partialArray("AXChildren")?.elements ?? [] },
        role:{ $0.attribute("AXRole") as? String },frame:{ EventStreamNativeChildren(parent:$0).frame() },
        isMacOS26OrLater:isMacOS26OrLater))
    }
}
