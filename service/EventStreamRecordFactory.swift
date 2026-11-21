import Foundation

struct EventStreamAXCaptureResult {
    var ax: EventStreamAXTree?
    var app: EventStreamApp?
    var window: EventStreamWindow?
}

struct EventStreamRecordDelivery {
    let record: EventStreamRecord
    let isSuppressed: Bool
}

// Final record construction. The capture dependency
// must perform the native selection/tree operation; no substitute tree or IPC
// recording success is manufactured when that producer is not connected.
@MainActor
final class EventStreamRecordFactory {
    private let nextIdentity: () -> EventStreamRecordIdentity
    private let capture: (EventStreamEventTarget?, Bool) async throws -> EventStreamAXCaptureResult
    private let onCaptureError: (Error) -> Void

    init(nextIdentity: @escaping () -> EventStreamRecordIdentity,
         capture: @escaping (EventStreamEventTarget?, Bool) async throws -> EventStreamAXCaptureResult,
         onCaptureError: @escaping (Error) -> Void = {
             FileHandle.standardError.write(Data("Failed to capture AX payload: \(String(reflecting: $0))\n".utf8))
         }) {
        self.nextIdentity = nextIdentity
        self.capture = capture
        self.onCaptureError = onCaptureError
    }

    func make(_ interaction: EventStreamPreparedInteraction) async -> EventStreamRecordDelivery {
        if !interaction.capturesAX {
            // The non-capturing shortcut branch preserves the
            // key-down target, without querying a later foreground context.
            return .init(record: EventStreamRecord(id: interaction.identity.id,
                timestamp: interaction.identity.timestamp, kind: interaction.kind,
                app: interaction.target.app, window: interaction.target.window,
                mouse: interaction.mouse, keyboard: interaction.keyboard), isSuppressed: false)
        }
        return await make(identity: interaction.identity, kind: interaction.kind,
            target: interaction.target, mouse: interaction.mouse, keyboard: interaction.keyboard,
            suppressWhenAXUnchanged: interaction.suppressWhenAXUnchanged)
    }

    func make(identity: EventStreamRecordIdentity? = nil, kind: EventStreamEventKind,
              target: EventStreamEventTarget? = nil, mouse: EventStreamMouseInteraction? = nil,
              keyboard: EventStreamKeyboardInteraction? = nil,
              preferDiff: Bool = true, suppressWhenAXUnchanged: Bool = false) async -> EventStreamRecordDelivery {
        let result: EventStreamAXCaptureResult
        do { result = try await capture(target, preferDiff) }
        catch {
            // Both context-selection and asynchronous tree failures recover to
            // the supplied target, with no debug record.
            onCaptureError(error)
            result = .init(ax: nil, app: target?.app, window: target?.window)
        }
        // Missing identities are allocated after capture, including failures.
        return Self.assemble(identity: identity ?? nextIdentity(), kind: kind, target: target,
            mouse: mouse, keyboard: keyboard, capture: result,
            suppressWhenAXUnchanged: suppressWhenAXUnchanged)
    }

    static func assemble(identity: EventStreamRecordIdentity, kind: EventStreamEventKind,
                         target: EventStreamEventTarget?, mouse: EventStreamMouseInteraction? = nil,
                         keyboard: EventStreamKeyboardInteraction? = nil,
                         capture: EventStreamAXCaptureResult,
                         suppressWhenAXUnchanged: Bool) -> EventStreamRecordDelivery {
        let input = [.mouseClick, .mouseContextMenu, .mouseDrag, .keyboardTextInput,
                     .keyboardSubmit, .keyboardShortcut].contains(kind)
        let preserveApp = input && (target?.app != nil || target?.window != nil)
        var mismatched = false
        if input, let target {
            if let expected = target.identity.processIdentifier, expected > 0,
               let actual = capture.app?.processIdentifier, actual > 0, expected != actual {
                mismatched = true
            }
            if let expected = target.identity.windowID, let actual = capture.window?.windowID, expected != actual {
                mismatched = true
            }
        }
        let ax = mismatched ? nil : capture.ax
        let useful = ax.map { !$0.text.hasPrefix("There has been no change") && $0.text != "no_change" } ?? false
        let record = EventStreamRecord(id: identity.id, timestamp: identity.timestamp, kind: kind,
            app: preserveApp ? target?.app : (capture.app ?? target?.app),
            window: mismatched ? target?.window : (capture.window ?? target?.window),
            mouse: mouse, keyboard: keyboard, ax: ax)
        return .init(record: record, isSuppressed: suppressWhenAXUnchanged && !useful)
    }
}
