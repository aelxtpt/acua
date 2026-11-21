import AppKit
import Foundation

/// An explicitly selected disposable socket harness. The controller, resolver,
/// launch, focus, cursor, AX, event and image providers retain native defaults.
/// Authenticated preparation, policy, power and analytics are owned test seams.
@MainActor enum NativeLiveAutomationWire {
    private static var trace:NativeDispatchTrace?
    static func install(traceURL:URL,target:URL,geometry:URL,deadline:Date) throws {
        let canonical=ComputerUseApplicationTarget.identifier(for:target)
        guard target.lastPathComponent=="OwnedLiveAutomation.app",
              Bundle(url:target)?.bundleIdentifier=="local.cua.owned-C145-live-automation",
              deadline.timeIntervalSinceNow>15 && deadline.timeIntervalSinceNow<=120 else {
            throw ServiceError(.invalidApp,"Invalid owned automation fixture or deadline")
        }
        let trace=NativeDispatchTrace(file:traceURL);self.trace=trace
        let validate: @Sendable () throws -> Void = {
            let metadata=ComputerUseTelemetryContext.snapshot()
            guard metadata.agentSessionID=="owned-C145-live",metadata.agentTurnID=="native",
                  deadline.timeIntervalSinceNow>10 else {
                throw ServiceError(.invalidApp,"Owned automation scope or deadline rejected")
            }
        }
        Dispatch.checkApplicationPolicy={raw in
            try validate()
            guard raw==canonical else { throw ServiceError(.invalidApp,"Only the owned automation fixture is admitted") }
            trace.add("policy")
        }
        Dispatch.checkGlobalConfiguration={try validate();trace.add("configuration")}
        Dispatch.prepareAuthenticatedRequest={_,_ in try validate();trace.add("prepare")}
        Dispatch.ensureSystemPermissions={_,_ in try validate();trace.add("permissions");return .granted}
        Dispatch.requestActivity = .init(provider:.init(create:{_,id in id=0;return 0},release:{_ in 0}))
        Dispatch.nativeUsage = .init(assembly:{
            try ControllerNativeAppSnapshotBackend.Assembly.approvedCursorNative(analytics:{_ in trace.add("analytics")},
                orderingLog:{_ in},log:{_,_ in})
        },observe:{controller,capture in
            precondition(controller.owner.applicationTarget.identifier==canonical)
            trace.add("native.capture")
            let owner=controller.owner
            let frame=owner.visibleRect
            let value:[String:Any]=["pid":owner.pid,"windowID":capture.axTree.selection.value.applicationWindow.nativeWindow.id,
                "scalingFactor":owner.scalingFactor,"visibleRect":[frame.minX,frame.minY,frame.width,frame.height],
                "imageSize":capture.imageSize.map{[$0.width,$0.height]} as Any? ?? NSNull(),
                "ownerActive":owner.isActive,"focusConstructed":owner.focusEnforcer != nil,
                "nativeProvidersIntercepted":false]
            do { try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:geometry,options:.atomic) }
            catch { preconditionFailure("Owned native geometry receipt failed") }
        })
        Dispatch.onApplicationUsed={id in trace.add("used");Dispatch.applicationUsed(id)}
    }
}
