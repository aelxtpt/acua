import CoreGraphics
import Foundation

/// Same generic VelocityVerletSimulation as SystemSettingsScalarSpring, with
/// the CGPoint/SIMD2 convergence norm and two cursor branches.
struct ControllerCursorMotionEngine: Sendable {
    struct Configuration: Sendable {
        var path = ControllerCursorMotionPath.Configuration()
        var positionResponse = 0.24
    }
    enum Mode: String, Sendable { case position, progress }
    struct Frame: Sendable {
        let point: CGPoint, velocity: CGPoint
        let progress: Double, distance: Double
        let finished: Bool
    }
    let start: CGPoint, end: CGPoint, mode: Mode
    let path: ControllerCursorMotionPath?
    let response: Double
    private var x: SystemSettingsScalarSpring
    private var y: SystemSettingsScalarSpring
    private var hasTicked = false
    init(start: CGPoint, end: CGPoint, bounds: CGRect, configuration: Configuration = .init()) {
        self.start = start; self.end = end
        let distance = hypot(end.x-start.x, end.y-start.y)
        if distance <= 196 {
            mode = .position; path = nil; response = configuration.positionResponse
            let c = SystemSettingsScalarSpring.Configuration(period: response, dampingFraction: 0.84, tolerance: 12)
            x = .init(configuration: c, value: start.x, target: end.x)
            y = .init(configuration: c, value: start.y, target: end.y)
        } else {
            mode = .progress
            let selected = ControllerCursorMotionPath.select(start: start, end: end, bounds: bounds, configuration: configuration.path)
            path = selected
            response = selected.response(metrics: selected.metrics(bounds: bounds, margin: configuration.path.margin), configuration: configuration.path)
            let c = SystemSettingsScalarSpring.Configuration(period: response, dampingFraction: 0.9, tolerance: 0.01)
            x = .init(configuration: c); y = .init(configuration: c)
        }
    }
    /// Rebase the first simulation tick to the display link's
    /// timestamp, then evolve to its predicted target timestamp.
    mutating func advance(frameTimestamp: Double, targetTimestamp: Double) -> Frame {
        if !hasTicked {
            x.setTime(frameTimestamp); y.setTime(frameTimestamp); hasTicked = true
        }
        return advance(to: targetTimestamp)
    }
    mutating func advance(to timestamp: Double) -> Frame {
        x.advance(to: timestamp)
        if mode == .position {
            y.advance(to: timestamp)
            let finished = positionIsComplete
            let point = finished ? end : CGPoint(x: x.value, y: y.value)
            let dx = end.x-start.x, dy = end.y-start.y, norm = dx*dx+dy*dy
            let progress = norm < 0.001 ? 1 : min(max(((point.x-start.x)*dx+(point.y-start.y)*dy)/norm, 0), 1)
            return .init(point: point, velocity: finished ? .zero : CGPoint(x: x.velocity, y: y.velocity),
                progress: progress, distance: hypot(end.x-point.x, end.y-point.y), finished: finished)
        }
        let finished = x.isComplete, progress = finished ? 1 : x.value
        let sample = path!.sample(at: progress)
        // Multiply the segment-local tangent by the segment count.
        let speed = finished ? 0 : x.velocity*Double(path!.segments.count)
        return .init(point: sample.point, velocity: CGPoint(x: sample.tangent.x*speed, y: sample.tangent.y*speed),
            progress: progress, distance: hypot(end.x-sample.point.x, end.y-sample.point.y), finished: finished)
    }
    private var positionIsComplete: Bool {
        let speed = x.velocity*x.velocity+y.velocity*y.velocity
        let acceleration = x.acceleration*x.acceleration+y.acceleration*y.acceleration
        if max(speed, acceleration) > 12*12 { return false }
        let tx = end.x*0.01, ty = end.y*0.01, tolerance = tx*tx+ty*ty
        let dx = end.x-x.value, dy = end.y-y.value
        if tolerance > 0 && dx*dx+dy*dy > tolerance { return false }
        return true
    }
}
