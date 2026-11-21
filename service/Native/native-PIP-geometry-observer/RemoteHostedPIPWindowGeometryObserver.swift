import AppKit
import ApplicationServices

@MainActor
final class RemoteHostedPIPWindowGeometryObserver {
    typealias Observation = PIPGeometryObservation<RemoteHostedPIPWindowServerObserver, SettingsNativeAXObserver, SettingsNativeAXElement>
    private let observation: Observation
    init?(windowID: CGWindowID, onGeometryChanged: @escaping Observation.Delivery,
          onSourceUnavailable: @escaping Observation.Delivery) {
        guard let observation = Observation(windowID:windowID,environment:Self.native,
            geometryChanged:onGeometryChanged,sourceUnavailable:onSourceUnavailable) else { return nil }
        self.observation=observation
    }
    private final class Info: @unchecked Sendable {
        let dictionary: CFDictionary?
        init(_ dictionary: CFDictionary?) { self.dictionary=dictionary }
    }
    private static var native: Observation.Environment {
        .init(lookupWindow:{ ControllerWindowDescription.lookup($0)?.id },
            observeCG:{ id,events,handler in
                RemoteHostedPIPWindowServerObserver(windowIDs:[id],events:events) {
                    _,event in handler(event)
                }
            },applicationWindow:applicationWindow,createAX:{ pid,handler in
                try SettingsNativeAXObserver(pid:pid,namedHandler:{ element,name,info in
                    // The shared AX wrapper accepts nil or a string-keyed dictionary.
                    guard info == nil || info as? [String:AnyObject] != nil else { return }
                    handler(element,name,Info(info))
                })
            },add:{ $0.add($1,$2) },start:{ $0.start($1) })
    }
    private enum LookupError: Error { case windowUnavailable(UInt32) }
    private static func record(_ value: ControllerWindowDescription) -> EventStreamNativeWindow {
        .init(id:value.id,processIdentifier:value.ownerPID,frame:value.bounds,level:Int(value.level),title:value.name,ownerName:value.ownerName)
    }
    private static func applicationWindow(_ id: UInt32) throws -> Observation.Target {
        // This performs its own lookup; the first channel's descriptor is not reused.
        guard let target=ControllerWindowDescription.lookup(id) else { throw LookupError.windowUnavailable(id) }
        let snapshots=EventStreamNativeSnapshots()
        let backend=EventStreamNativeContextBackend(nodeProvider:{ snapshots.node($0) },
            windowReader:{ ControllerWindowDescription.lookup($0).map(record) },listReader:{ options in
                (CGWindowListCopyWindowInfo(options,0) as? [[AnyHashable:Any]] ?? []).map { record(.init(info:$0)) }
            })
        let application=backend.application(target.ownerPID)
        let candidates=backend.matchingWindows()
        let resolver=EventStreamContextResolver(backend:backend)
        for window in backend.nodes(application,"AXWindows") {
            if resolver.matchingWindow(for:window,applicationPID:target.ownerPID,candidates:candidates)?.id == target.id {
                return .init(pid:target.ownerPID,application:.init(element:application.element),window:.init(element:window.element))
            }
        }
        throw LookupError.windowUnavailable(id)
    }
}
