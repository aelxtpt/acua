import Foundation

struct EventStreamRecordIdentity: Equatable {
    let id: Int
    let timestamp: Date
}

struct EventStreamEventTargetIdentity: Equatable {
    var processIdentifier: Int32?
    var windowID: UInt32?
}

struct EventStreamEventTarget {
    var identity: EventStreamEventTargetIdentity
    var app: EventStreamApp?
    var window: EventStreamWindow?
}

// Text-input paths. Context lookup and AX refresh
// are required dependencies: this component alone does not start native capture.
@MainActor
final class EventStreamTextInputRecorder<Target> {
    struct CapturedTarget {
        var description: EventStreamAXElement?
        var element: Target?
    }

    private let nextIdentity: () -> EventStreamRecordIdentity
    private let refreshTarget: (Target) -> EventStreamAXElement
    private let resolveContext: (EventStreamEventTarget?) -> (EventStreamApp?, EventStreamWindow?)
    private let emit: (EventStreamRecord) -> Void
    private let isRecording: () -> Bool
    private let sleep: (Duration) async throws -> Void
    private let lifetimeOwner:()->AnyObject?
    private var flushTask: Task<Void, Never>?
    private var targetIdentity: EventStreamEventTargetIdentity?
    private var eventTarget: EventStreamEventTarget?
    private var cachedTarget: EventStreamAXElement?
    private var targetElement: Target?
    private(set) var text = ""

    init(nextIdentity: @escaping () -> EventStreamRecordIdentity,
         refreshTarget: @escaping (Target) -> EventStreamAXElement,
         resolveContext: @escaping (EventStreamEventTarget?) -> (EventStreamApp?, EventStreamWindow?),
         isRecording: @escaping () -> Bool,
         sleep: @escaping (Duration) async throws -> Void = { try await ContinuousClock().sleep(for: $0) },
         lifetimeOwner:@escaping ()->AnyObject? = {nil},
         emit: @escaping (EventStreamRecord) -> Void) {
        self.nextIdentity = nextIdentity
        self.refreshTarget = refreshTarget
        self.resolveContext = resolveContext
        self.isRecording = isRecording
        self.sleep = sleep
        self.lifetimeOwner=lifetimeOwner
        self.emit = emit
    }

    // Caller classifies native key-downs before entering this path. Mouse-downs
    // and non-text keys flush the buffer through the recorder's other paths.
    func append(_ characters: String, target: EventStreamEventTarget,
                captureTarget: () -> CapturedTarget) {
        append(characters, targetIdentity: target.identity,
               resolveTarget: { target }, captureTarget: { _ in captureTarget() })
    }

    func append(_ characters: String, targetIdentity identity: EventStreamEventTargetIdentity,
                resolveTarget: () -> EventStreamEventTarget,
                captureTarget: (EventStreamEventTarget) -> CapturedTarget) {
        guard !characters.isEmpty else { return }
        if !text.isEmpty && targetIdentity != identity { flush() }
        if text.isEmpty {
            let target = resolveTarget()
            let captured = captureTarget(target)
            cachedTarget = captured.description
            targetElement = captured.element
            targetIdentity = identity
            eventTarget = target
        }
        // Each key advances the shared identity counter, then
        // allocates another identity at flush. Key identities are not emitted.
        _ = nextIdentity()
        text.append(characters)
        scheduleFlush()
    }

    func flush() {
        guard !text.isEmpty else { return }
        let target = targetElement.map(refreshTarget) ?? cachedTarget
        let outputText = Self.isSensitive(target) ? nil : text
        let capturedContext = eventTarget
        let identity = nextIdentity()
        // Clear before context lookup / emission: callbacks may start a buffer.
        discard()
        let (app, window) = resolveContext(capturedContext)
        emit(EventStreamRecord(id: identity.id, timestamp: identity.timestamp,
             kind: .keyboardTextInput, app: app, window: window,
             keyboard: EventStreamKeyboardInteraction(text: outputText,
                 keyEquivalent: nil, modifiers: [], target: target)))
    }

    func cancelPendingFlush() {
        flushTask?.cancel()
        flushTask = nil
    }

    func clearBuffer() {
        text = ""
        targetIdentity = nil
        eventTarget = nil
        cachedTarget = nil
        targetElement = nil
    }

    func discard() {cancelPendingFlush();clearBuffer()}

    // Examines six descriptor fields, excluding value. This is a heuristic,
    // not a guarantee that every sensitive field is found.
    static func isSensitive(_ target: EventStreamAXElement?) -> Bool {
        guard let target else { return false }
        let description = [target.role, target.subrole, target.title,
                           target.description, target.placeholder, target.identifier]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        return description.contains("password") || description.contains("secure")
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        let owner=lifetimeOwner()
        flushTask = Task { @MainActor [self,owner] in
            defer {withExtendedLifetime(owner) {}}
            // Common delayed flush.
            try? await sleep(.milliseconds(750))
            guard !Task.isCancelled,isRecording() else {return}
            flush()
        }
    }

    deinit { flushTask?.cancel() }
}
