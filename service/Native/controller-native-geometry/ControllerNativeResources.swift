import ApplicationServices
import Foundation

/// One instance belongs to the runtime, shared by all controllers and temporary
/// focus assertions. Construction binds providers; it starts no event taps.
final class ControllerNativeResources: Sendable {
    typealias Focus = ControllerFocusNativeBindings.Focus
    typealias Enablement = ControllerAXEnablement<ControllerAXEnablementApplication, ControllerNativeElementContext.Node, Focus>
    let context: ControllerNativeElementContext
    let io: ControllerNativeElementIO
    let geometry: ControllerNativeGeometry
    let actions: ControllerFocusSynthesizedActionState
    let prevention: ControllerGlobalFocusRegistry<ControllerFocusNativeEvent>
    let windowServer: ControllerNativeWindowServer

    init(context: ControllerNativeElementContext, lookup: @escaping ControllerNativeElementIO.Lookup,
         windowServer: ControllerNativeWindowServer, actions: ControllerFocusSynthesizedActionState = .shared) {
        let io = ControllerNativeElementIO(lookup: lookup)
        let context = io.bind(context)
        self.io = io; self.context = context; self.actions = actions; self.windowServer = windowServer
        geometry = .init(context: context, io: io)
        prevention = ControllerGlobalFocusNative.registry(context: context, ordinaryPID: { lookup($0)?.ordinaryPID }, synthesizedActions: actions)
    }
    var focusEnvironment: Focus.Environment {
        let reader = geometry
        return ControllerFocusNativeBindings.environment(context: context, prevention: prevention.focusBindings,
            windowServer: windowServer.bindings, activationPoint: { reader.activationPoint($0) },
            frame: { reader.frame($0) }, raise: { try reader.raise($0) }, synthesizedActions: actions)
    }
    func makeFocus(_ pid: Int32) -> Focus { .init(pid: pid, environment: focusEnvironment) }
    var enablement: Enablement {
        let environment = ControllerAXEnablementNative.environment(context: context,
            pid: { try ControllerAXEnablementNative.pid($0, lookup: { self.io.lookup($0)?.ordinaryPID }) },
            bridgedWrite: { key, name, value in
                guard let bridge = self.io.lookup(key) else { return false }
                try bridge.setBoolean(name, value); return true
            }, makeFocus: { self.makeFocus($0.application.processIdentifier) },
            enforceFocus: { try $0.enforceActiveState(for: $1) }, deactivateFocus: { try $0.deactivateFocusEnforcer() })
        return .init(tracker: ControllerAXEnablementNativeTracker.shared.tracker, environment: environment)
    }
}
