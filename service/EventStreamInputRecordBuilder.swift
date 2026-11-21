import Foundation
import CoreGraphics

struct EventStreamPreparedInteraction {
    let identity: EventStreamRecordIdentity
    let kind: EventStreamEventKind
    let target: EventStreamEventTarget
    let mouse: EventStreamMouseInteraction?
    let keyboard: EventStreamKeyboardInteraction?
    let capturesAX: Bool
    let suppressWhenAXUnchanged: Bool
}

// Stateful input side of EventStreamRecorder. The required prepare callback
// hands off to the native AX/tree/context record factory, still owned by the
// complete producer. This class does not install a tap or publish IPC handlers.
@MainActor
final class EventStreamInputRecordBuilder<Target> {
    typealias CapturedTarget = EventStreamTextInputRecorder<Target>.CapturedTarget
    private struct MouseDown {
        let button: String?
        let location: CGPoint
        let endpoint: EventStreamMouseInteractionDragEndpoint?
    }
    private let nextIdentity: () -> EventStreamRecordIdentity
    private let isRecording: () -> Bool
    private let fallbackProcessIdentifier: () -> Int32?
    private let capturePermitted: (Int32?) -> Bool
    private let keyboardTarget: (EventStreamEventTargetIdentity) -> EventStreamEventTargetIdentity
    private let resolveTarget: (EventStreamEventTargetIdentity) -> EventStreamEventTarget
    private let endpointAt: (EventStreamEventTarget, CGPoint) -> EventStreamMouseInteractionDragEndpoint?
    private let focusedTarget: (EventStreamEventTarget) -> CapturedTarget
    private let refreshTarget: (Target) -> EventStreamAXElement
    private let currentRole: (Target) -> String?
    private let characterCount: (Target) -> Int?
    private let sleep: (Duration) async throws -> Void
    private let lifetimeOwner:()->AnyObject?
    private let prepare: (EventStreamPreparedInteraction) -> Void
    private let textRecorder: EventStreamTextInputRecorder<Target>
    private var mouseDown: MouseDown?
    private var delayed: [UUID: Task<Void, Never>] = [:]
    var pendingInteractionCount: Int { delayed.count }

    init(nextIdentity: @escaping () -> EventStreamRecordIdentity,
         isRecording: @escaping () -> Bool,
         fallbackProcessIdentifier: @escaping () -> Int32?,
         capturePermitted: @escaping (Int32?) -> Bool,
         keyboardTarget: @escaping (EventStreamEventTargetIdentity) -> EventStreamEventTargetIdentity,
         resolveTarget: @escaping (EventStreamEventTargetIdentity) -> EventStreamEventTarget,
         endpointAt: @escaping (EventStreamEventTarget, CGPoint) -> EventStreamMouseInteractionDragEndpoint?,
         focusedTarget: @escaping (EventStreamEventTarget) -> CapturedTarget,
         refreshTarget: @escaping (Target) -> EventStreamAXElement,
         currentRole: @escaping (Target) -> String?,
         characterCount: @escaping (Target) -> Int?,
         resolveTextContext: @escaping (EventStreamEventTarget?) -> (EventStreamApp?, EventStreamWindow?),
         sleep: @escaping (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) },
         lifetimeOwner:@escaping ()->AnyObject? = {nil},
         emitText: @escaping (EventStreamRecord) -> Void,
         prepare: @escaping (EventStreamPreparedInteraction) -> Void) {
        self.nextIdentity = nextIdentity; self.isRecording = isRecording
        self.fallbackProcessIdentifier = fallbackProcessIdentifier
        self.capturePermitted = capturePermitted; self.keyboardTarget = keyboardTarget
        self.resolveTarget = resolveTarget; self.endpointAt = endpointAt
        self.focusedTarget = focusedTarget; self.refreshTarget = refreshTarget
        self.currentRole = currentRole; self.characterCount = characterCount
        self.sleep = sleep; self.prepare = prepare
        self.lifetimeOwner=lifetimeOwner
        textRecorder = .init(nextIdentity: nextIdentity, refreshTarget: refreshTarget,
            resolveContext: resolveTextContext, isRecording: isRecording, sleep: sleep,lifetimeOwner:lifetimeOwner, emit: emitText)
    }

    func receive(_ observation: EventStreamInputObservation) {
        guard isRecording(), EventStreamInputPolicy.eventTypes.contains(observation.type),
              capturePermitted(observation.target.processIdentifier ?? fallbackProcessIdentifier()) else { return }
        let identity = EventStreamEventTargetIdentity(processIdentifier: observation.target.processIdentifier,
                                                     windowID: observation.target.windowID)
        switch observation.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            textRecorder.flush()
            let target = resolveTarget(identity)
            mouseDown = .init(button: EventStreamInputPolicy.button(observation.type),
                location: observation.location, endpoint: endpointAt(target, observation.location))
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            receiveMouseUp(observation, identity: identity)
        case .keyDown:
            receiveKey(observation, identity: identity.windowID == nil ? keyboardTarget(identity) : identity)
        default: break
        }
    }

    func flushText() { textRecorder.flush() }

    // Recorder reset/stop owns these independently. Already scheduled 250ms
    // interactions are not part of the recorder's cancellation inventory.
    func clearMouseDown() {mouseDown=nil}
    func clearTextBuffer() {textRecorder.clearBuffer()}
    func cancelTextFlush() {textRecorder.cancelPendingFlush()}

    // Owner flushes before stop; discard alone intentionally emits no records.
    func discardPendingInput() {
        for task in delayed.values { task.cancel() }
        delayed.removeAll()
        mouseDown = nil
        textRecorder.discard()
    }

    private func receiveMouseUp(_ observation: EventStreamInputObservation,
                                identity: EventStreamEventTargetIdentity) {
        let target = resolveTarget(identity)
        let down = mouseDown
        let button = EventStreamInputPolicy.button(observation.type)
        let drag = EventStreamInputPolicy.isDrag(button: button, originButton: down?.button,
            origin: down?.location, destination: observation.location)
        // Drag destination is hit-tested system-wide, without the source event
        // window constraining its endpoint.
        let hitContext = drag ? EventStreamEventTarget(identity: .init()) : target
        let destination = endpointAt(hitContext, observation.location)
        let mouse = EventStreamMouseInteraction(button: button, clickCount: Int(observation.clickCount),
            modifiers: EventStreamInputPolicy.modifiers(observation.flags),
            target: drag ? down?.endpoint?.element : destination?.element,
            origin: drag ? down?.endpoint : nil, destination: drag ? destination : nil)
        mouseDown = nil
        let kind = EventStreamInputPolicy.mouseKind(button: button, flags: observation.flags, isDrag: drag)
        guard !EventStreamInteractionPolicy.omitMouse(kind: kind, mouse: mouse) else { return }
        let recordIdentity = nextIdentity()
        let suppress = EventStreamInteractionPolicy.suppressMouseWhenAXUnchanged(kind: kind, mouse: mouse)
        afterInteraction { builder in
            builder.prepare(.init(identity: recordIdentity, kind: kind, target: target,
                mouse: mouse, keyboard: nil, capturesAX: true, suppressWhenAXUnchanged: suppress))
        }
    }

    private func receiveKey(_ observation: EventStreamInputObservation,
                            identity: EventStreamEventTargetIdentity) {
        guard let code = observation.keyCode else { return }
        if EventStreamInputPolicy.isTextInput(keyCode: code, characters: observation.characters, flags: observation.flags) {
            textRecorder.append(observation.characters, targetIdentity: identity,
                resolveTarget: { resolveTarget(identity) }, captureTarget: focusedTarget)
            return
        }
        textRecorder.flush()
        let recordIdentity = nextIdentity()
        let target = resolveTarget(identity)
        let focused = focusedTarget(target)
        let keyboard = EventStreamKeyboardInteraction(keyEquivalent: EventStreamInputPolicy.keyEquivalent(
            keyCode: code, charactersIgnoringModifiers: observation.charactersIgnoringModifiers),
            modifiers: EventStreamInputPolicy.modifiers(observation.flags), target: focused.description)
        afterInteraction { builder in
            let capturedRole = focused.description?.role
            var currentRole: String?, count: Int?
            if capturedRole == "AXTextArea" && (code == 36 || code == 76), let element = focused.element {
                currentRole = builder.currentRole(element)
                if currentRole == "AXTextArea",
                   observation.flags.intersection([.maskControl, .maskAlternate, .maskShift]).isEmpty {
                    count = builder.characterCount(element)
                }
            }
            let decision = EventStreamInteractionPolicy.keyboard(keyCode: code, flags: observation.flags,
                capturedRole: capturedRole, currentRole: currentRole, currentCharacterCount: count,
                bundleIdentifier: target.app?.bundleIdentifier)
            var payload = keyboard
            if decision.capturesAX, let element = focused.element { payload.target = builder.refreshTarget(element) }
            builder.prepare(.init(identity: recordIdentity, kind: decision.kind, target: target,
                mouse: nil, keyboard: payload, capturesAX: decision.capturesAX, suppressWhenAXUnchanged: false))
        }
    }

    private func afterInteraction(_ body: @escaping (EventStreamInputRecordBuilder) -> Void) {
        let token = UUID()
        let owner=lifetimeOwner()
        delayed[token] = Task { @MainActor [self,owner] in
            defer {withExtendedLifetime(owner) {}}
            try? await sleep(.milliseconds(250))
            delayed.removeValue(forKey: token)
            guard !Task.isCancelled,isRecording() else {return}
            body(self)
        }
    }

    deinit { for task in delayed.values { task.cancel() } }
}
