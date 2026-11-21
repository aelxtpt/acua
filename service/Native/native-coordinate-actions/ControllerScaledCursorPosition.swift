import Foundation

/// Stores two signed 64-bit screenshot coordinates. Convert only when
/// applying the current scale/origin, so the stored value survives >2^53.
struct ControllerScaledCursorPosition: Sendable, Equatable {
    let x: Int64
    let y: Int64
    static let zero = Self(x: 0, y: 0)
    var point: CGPoint { .init(x: CGFloat(x), y: CGFloat(y)) }
    func global(scale: CGFloat, origin: CGPoint) -> CGPoint {
        point.applying(.init(scaleX: scale, y: scale))
            .applying(.init(translationX: origin.x, y: origin.y))
    }
}
