import AppKit
import ApplicationServices
import Foundation

@MainActor struct ControllerNativeKeyboardTarget: ControllerKeyboardTargetBackend {
    typealias Node = ControllerNativeElementContext.Node
    let resources: ControllerNativeResources
    func ordinaryPID(_ application: Node) throws -> Int32 {
        try ControllerAXEnablementNative.pid(application.element, lookup: { resources.io.lookup($0)?.ordinaryPID })
    }
    func focusedElement(_ application: Node) -> Node? {
        ControllerGlobalFocusNative.element("AXFocusedUIElement", application, context: resources.context)
    }
    func parent(_ element: Node) -> Node? { ControllerGlobalFocusNative.element("AXParent", element, context: resources.context) }
    func actualPID(_ element: Node) throws -> Int32 { try resources.context.identity.actualPID(element.element) }
    func processKind(_ pid: Int32) -> ControllerKeyboardProcessKind {
        guard let app = NSRunningApplication(processIdentifier: pid), app.isFinishedLaunching else { return .unavailable }
        return app.activationPolicy == .prohibited ? .service : .application
    }
    func missingContainingProcess() {
        resources.context.log("log[24579732a7739189470a]", ControllerMouseTargetFailure.unresolvedContext(reason: 0))
    }
}

enum ControllerNativeKeyboardEvents {
    typealias Event = ControllerFocusNativeEvent
    ///Keep the async construction boundary used by pressKeys, separate from
    ///the MainActor request/controller and focus preparation.
    nonisolated static func make(_ strokes: [ControllerKeyboardStroke]) async throws -> [Event] {
        try factory().make(strokes)
    }
    nonisolated static func factory() -> ControllerKeyboardEventFactory<CGEventSource, Event> {
        .init(source: { CGEventSource(stateID: .hidSystemState) },
            currentFlags: { CGEventSource.flagsState(.combinedSessionState).rawValue }, flagsEvent: { source, flags in
                guard let event = CGEvent(source: source) else { return nil }
                event.type = .flagsChanged; event.flags = .init(rawValue: flags)
                return .init(event: event)
            }, keyboardEvent: { source, code, down, flags, unicode in
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return nil }
                event.flags = .init(rawValue: flags)
                if var unicode {
                    event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: &unicode)
                }
                return .init(event: event)
            })
    }
    nonisolated static func send(_ events: [Event], to pid: Int32) async {
        ControllerKeyboardImmediateSender<Event>(timestamp: { DispatchTime.now().uptimeNanoseconds },
            setTimestamp: { $0.event.timestamp = $1 }, post: { $0.event.postToPid($1) }).send(events, to: pid)
    }
}

extension ControllerNativeSetValueRuntime {
    ///Concrete Return targeting, generation and delivery. No legacy handler
    ///or fabricated-success keyboard capability participates in this runtime.
    static func native(resources: ControllerNativeResources) -> Self {
        .native(resources: resources, pressReturn: { application in
            let target = try ControllerKeyboardTargeting(backend: ControllerNativeKeyboardTarget(resources: resources)).target(application)
            let key = try ControllerHeldClickKey.parse("Return")
            guard let code = key.keyCode else { throw ControllerHeldClickKeyFailure.requiresSingleNonemptyStroke }
            let events = try await ControllerNativeKeyboardEvents.make([.init(keyCode: code, flags: key.eventFlags, unicode: nil)])
            await ControllerNativeKeyboardEvents.send(events, to: target.pid)
            withExtendedLifetime(target) {}
        })
    }
}
