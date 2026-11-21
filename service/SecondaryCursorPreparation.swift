import Foundation

enum SecondaryCursorPreparation {
    struct Position { let point: CGPoint?; let scrolled: Bool }
    enum Failure: Error { case noFrame }
    static let pressAnimationSeconds = 0.05
    static let pressHoldSeconds = 0.05

    static func position(specialPoint: () throws -> CGPoint?, frame: () throws -> CGRect?,
        scroll: (CGRect) throws -> Bool, visiblePoint: (CGRect) throws -> CGPoint?,
        checkpoint: () throws -> Void) throws -> Position {
        try checkpoint()
        if let point = try specialPoint() { return Position(point: point, scrolled: false) }
        guard let initial = try frame() else { throw Failure.noFrame }
        // Attempt the reveal before ordinary point calculation,
        // even when a control already appears visible or the cursor is off.
        let scrolled = try scroll(initial)
        try checkpoint()
        guard let final = try frame() else { throw Failure.noFrame }
        return Position(point: try visiblePoint(final), scrolled: scrolled)
    }

    static func prepare<T>(_ target: T, position: (T) throws -> Position,
        cursorEnabled: () -> Bool, move: (T, CGPoint) throws -> Void,
        refetch: () throws -> T, validate: (T) throws -> Void,
        checkpoint: () throws -> Void, prepareFocus: () throws -> Void = {}) throws -> T {
        try checkpoint()
        try prepareFocus()
        let placed = try position(target)
        try checkpoint()
        if let point = placed.point, cursorEnabled() { try move(target, point) }
        try checkpoint()
        let result = placed.scrolled ? try refetch() : target
        try checkpoint()
        try validate(result)
        try checkpoint()
        return result
    }
}
