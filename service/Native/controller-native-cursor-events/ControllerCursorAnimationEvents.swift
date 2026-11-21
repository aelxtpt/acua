import CoreGraphics
import Foundation

/// valueChanged fires only for unequal stored values; normal
/// convergence first publishes target then finished. The native window owns
/// callback slots and display-link lifetime separately from this value stream.
struct ControllerCursorAnimationEvents: Sendable {
    enum Event: Sendable {
        case valueChanged(ControllerCursorMotionEngine.Frame)
        case finished(ControllerCursorMotionEngine.Frame)
    }
    private enum Value: Equatable, Sendable { case point(CGPoint), progress(Double) }
    private var engine: ControllerCursorMotionEngine
    private var value: Value
    private(set) var isFinished = false
    init(start: CGPoint, end: CGPoint, bounds: CGRect, configuration: ControllerCursorMotionEngine.Configuration = .init()) {
        engine = .init(start: start, end: end, bounds: bounds, configuration: configuration)
        value = engine.mode == .position ? .point(start) : .progress(0)
    }
    mutating func advance(timestamp: Double, targetTimestamp: Double) -> [Event] {
        guard !isFinished else { return [] }
        let frame = engine.advance(frameTimestamp: timestamp, targetTimestamp: targetTimestamp)
        let next: Value = engine.mode == .position ? .point(frame.point) : .progress(frame.progress)
        var events: [Event] = []
        if next != value {
            value = next
            events.append(.valueChanged(.init(point: frame.point, velocity: frame.velocity,
                progress: frame.progress, distance: frame.distance, finished: false)))
        }
        if frame.finished { isFinished = true; events.append(.finished(frame)) }
        return events
    }
}
