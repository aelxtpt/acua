import AppKit
import ApplicationServices
import Foundation

/// Fresh AX values bypass transaction caches. The attribute mask, however,
/// comes from the focused wrapper captured before observation starts.
final class ControllerNativePasteObservation: @unchecked Sendable {
    typealias Instant = SuspendingClock.Instant
    typealias Node = ControllerNativeElementContext.Node
    let state: ControllerPasteObservationBox<Instant>
    let keys: [String]
    let initialValues: ControllerPasteValues?
    private let readValues: (@Sendable () throws -> ControllerPasteValues)?
    private let registration: ControllerPasteObserverRegistration<ControllerAXNativeObserver>?

    init(pid: Int32, focused: Node?, io: ControllerNativeElementContext.IO?,
         logRegistrationError: @escaping @Sendable (String, Error) -> Void) throws {
        let state = ControllerPasteObservationBox<Instant>()
        self.state = state
        let keys = ["AXSelectedTextRange", "AXNumberOfCharacters", "AXValue"].filter {
            focused?.snapshot.supported.contains($0) == true
        }
        self.keys = keys
        let reader: (@Sendable () throws -> ControllerPasteValues)?
        if let focused, !keys.isEmpty {
            reader = {
                let values: [String:ControllerNativeAXValue]
                if let io { values = try io.batch(focused.element, Set(keys)) }
                else {
                    var raw: CFArray?
                    let status = AXUIElementCopyMultipleAttributeValues(focused.element.element, keys as CFArray, [], &raw)
                    guard [.success, .noValue, .attributeUnsupported].contains(status) else { throw ControllerNativeElementDecoding.Failure.accessibility(status.rawValue) }
                    guard let raw = raw as? [AnyObject] else { throw ControllerNativeElementDecoding.Failure.missingResponse }
                    values = try ControllerNativeElementDecoding.batch(names: keys, response: raw)
                }
                return values.mapValues { .init(raw: $0.raw) }
            }
        } else { reader = nil }
        readValues = reader
        initialValues = try? reader?()
        let application = SettingsNativeAXElement(element: AXUIElementCreateApplication(pid))
        registration = .make(environment: .init(create: { edited in
            try ControllerAXNativeObserver(pid: pid) { _, _, _ in edited() }
        }, register: { observer, name in
            let status = observer.add(application, name)
            guard status == AXError.success.rawValue || status == AXError.notificationAlreadyRegistered.rawValue else {
                throw ControllerAXNativeObserver.Failure(status: status)
            }
        }, start: { $0.start($1) }, stop: { $0.stop() }, logRegistrationError: logRegistrationError), edited: {
            let time = SuspendingClock.now
            state.withState { $0.edited(at: time) }
        })
    }

    var hasObserver: Bool { registration != nil }
    func markDispatched() { state.withState { $0.dispatchAt = SuspendingClock.now } }
    func stop() { registration?.stop() }

    @MainActor func pasteboardBackend(_ board: NSPasteboard,
        logOwnershipLost: @escaping @MainActor () -> Void) -> ControllerNativePasteboardBackend {
        let state = state
        return .init(pasteboard: board, readStarted: { start in state.withState { $0.readStarted(at: start) } },
            readFinished: { start, end, succeeded in state.withState { $0.readFinished(start: start, end: end, succeeded: succeeded) } },
            logOwnershipLost: logOwnershipLost)
    }

    func acknowledgementPoll(restore: @escaping @MainActor @Sendable () -> Bool)
        -> ControllerPasteAcknowledgementPoll<Instant, ControllerPasteValues> {
        let asyncReader: (@Sendable () async throws -> ControllerPasteValues)?
        if let reader = readValues { asyncReader = { @Sendable in try reader() } }
        else { asyncReader = nil }
        return .init(observation: state, initialValues: initialValues, now: { SuspendingClock.now },
            cancelled: { Task.isCancelled }, restore: restore, readValues: asyncReader,
            changed: { ControllerNativePasteValueChanges.changed(from: $0, to: $1) })
    }
}
