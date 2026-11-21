import Foundation
import CoreGraphics

enum ControllerActionDispatchFailure: Error, Equatable {
    case invalidElementID, invalidDuration, invalidScrollPages
}
@MainActor protocol ControllerActionDispatchBackend {
    associatedtype AppSnapshot
    func coordinateClick(_ options: ControllerCoordinateClickParameters) async throws -> AppSnapshot?
    func elementClick(_ options: ControllerClickParameters) async throws -> AppSnapshot?
    func secondary(elementID: Int, action: String, returnAppSnapshot: Bool) async throws -> AppSnapshot?
    func setValue(_ options: ControllerSetValueParameters) async throws -> AppSnapshot?
    func selectText(_ options: ControllerTextSelectionParameters) async throws -> AppSnapshot?
    func scroll(at: XPCAppUsageBody.Target, direction: XPCAppUsageBody.ComputerUseIPCScrollDirection,
                pages: Double, returnAppSnapshot: Bool) async throws -> AppSnapshot?
    func keyboard(_ options: ControllerKeyboardActionParameters) async throws -> AppSnapshot?
    func paste(_ options: ControllerPasteParameters) async throws -> AppSnapshot?
}

@MainActor struct ControllerActionDispatch<Backend: ControllerActionDispatchBackend> {
    let backend: Backend
    static func elementID(_ raw: String) throws -> Int {
        guard let value = Int(raw) else { throw ControllerActionDispatchFailure.invalidElementID }
        return value
    }
    static func position(_ point: CGPoint) -> ControllerScaledCursorPosition {
        // Nonfinite/out-of-range values trap, as the Int64 conversion does.
        .init(x: Int64(point.x), y: Int64(point.y))
    }
    static func duration(_ value: Double?) throws -> Duration? {
        guard let value else { return nil }
        guard value >= 0 && value <= 30 else { throw ControllerActionDispatchFailure.invalidDuration }
        return .seconds(value)
    }
    func perform(_ action: XPCAppUsageBody.Action, returnAppSnapshot: Bool) async throws -> Backend.AppSnapshot? {
        switch action {
        case .click(let target, let button, let count, let seconds, let key):
            let hold = try Self.duration(seconds)
            switch target {
            case .coordinate(let point):
                return try await backend.coordinateClick(.init(position: Self.position(point), button: button,
                    count: count, hold: hold, key: key, returnAppSnapshot: returnAppSnapshot, animateCursor: true))
            case .elementID(let raw):
                return try await backend.elementClick(.init(elementID: Self.elementID(raw),
                    button: button == 1 ? .right : .left, count: count, hold: hold, key: key,
                    returnAppSnapshot: returnAppSnapshot, animateCursor: false))
            }
        case .performSecondaryAction(let raw, let action):
            return try await backend.secondary(elementID: Self.elementID(raw), action: action, returnAppSnapshot: returnAppSnapshot)
        case .setValue(let raw, let value):
            return try await backend.setValue(.init(elementID: Self.elementID(raw), value: value,
                autosubmitSearchFields: returnAppSnapshot, returnAppSnapshot: returnAppSnapshot))
        case .selectText(let raw, let text, let prefix, let suffix, let selection):
            let mode: ControllerTextSelectionMode
            switch selection { case .text: mode = .text; case .cursorBefore: mode = .cursorBefore; case .cursorAfter: mode = .cursorAfter }
            return try await backend.selectText(.init(elementID: Self.elementID(raw), text: text,
                prefix: prefix, suffix: suffix, selection: mode, returnAppSnapshot: returnAppSnapshot))
        case .scroll(let target, let direction, let pages):
            guard pages > 0 else { throw ControllerActionDispatchFailure.invalidScrollPages }
            return try await backend.scroll(at: target, direction: direction, pages: pages, returnAppSnapshot: returnAppSnapshot)
        case .drag(let from, let to):
            return try await backend.coordinateClick(.init(position: Self.position(from), destination: Self.position(to),
                button: 0, count: 1, returnAppSnapshot: returnAppSnapshot, animateCursor: true))
        case .pressKey(let text, let seconds):
            let hold = try Self.duration(seconds)
            return try await backend.keyboard(.init(kind: hold == nil ? .press : .hold, text: text,
                duration: hold, waitForUIToSettle: true, returnAppSnapshot: returnAppSnapshot))
        case .type(let text):
            return try await backend.keyboard(.init(kind: .type, text: text, duration: nil,
                waitForUIToSettle: true, returnAppSnapshot: returnAppSnapshot))
        case .paste(let text, let format):
            let value: ControllerPasteFormat
            switch format { case .text: value = .text; case .md: value = .markdown; case .html: value = .html }
            return try await backend.paste(.init(text: text, format: value, returnAppSnapshot: returnAppSnapshot))
        }
    }
}
