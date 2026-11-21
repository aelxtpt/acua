import CoreGraphics
import Foundation

/// Cursor motion path. Segment records store end, first control, second
/// control; a two-segment candidate additionally retains its middle point.
struct ControllerCursorMotionPath: Sendable {
    struct Configuration: Sendable {
        var angle = -44.0
        var candidateCount = 20
        var margin = 20.0
        var startHandle = 0.41960295031576633
        var endHandle = 0.15
        var arcSize = 0.2765523188064277
        var arcFlow = 0.5783555327868779
        var straightDistance = 10.0
        var responseScale = 0.9
        var minimumResponse = 0.12
        var maximumResponse = 2.2
    }
    struct Segment: Sendable {
        let end: CGPoint, control1: CGPoint, control2: CGPoint
    }
    struct Metrics: Sendable {
        let length: Double, squaredTurns: Double, maximumTurn: Double, totalTurn: Double
        let inBounds: Bool
    }
    let start: CGPoint, end: CGPoint
    let segments: [Segment]
    let middle: CGPoint?

    static func bounds(start: CGPoint, end: CGPoint, targetFrame: CGRect?, screens: [CGRect]) -> CGRect {
        if let targetFrame { return CGRect(origin: .zero, size: targetFrame.size) }
        for screen in screens where screen.contains(start) || screen.contains(end) { return screen }
        return screens.reduce(.null) { $0.union($1) }
    }
    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
    private static func add(_ a: CGPoint, _ b: CGPoint, _ scale: Double = 1) -> CGPoint {
        CGPoint(x: a.x+b.x*scale, y: a.y+b.y*scale)
    }
    private static func unit(_ a: CGPoint) -> CGPoint {
        let length = hypot(a.x, a.y)
        return length < 0.001 ? CGPoint(x: 1, y: 0) : CGPoint(x: a.x/length, y: a.y/length)
    }
    static func candidates(start: CGPoint, end: CGPoint, configuration c: Configuration = .init()) -> [Self] {
        precondition(c.candidateCount >= 0)
        let delta = CGPoint(x: end.x-start.x, y: end.y-start.y)
        let distance = hypot(delta.x, delta.y), direction = unit(delta)
        let angle = c.angle * .pi / 180
        let heading = CGPoint(x: sin(angle), y: cos(angle))
        let first = clamp(min(distance*c.startHandle, distance*0.9), 48, 640)
        let last = clamp(min(distance*c.endHandle, distance*0.9), 48, 640)
        let c1 = add(start, heading, first), c2 = add(end, heading, -last)
        var result: [Self] = [
            .init(start: start, end: end, segments: [.init(end: end, control1: c1, control2: c2)], middle: nil),
            .init(start: start, end: end, segments: [.init(end: end, control1: add(start, heading, first*0.65),
                 control2: add(end, heading, -last*0.65))], middle: nil)
        ]
        let side = cos(angle)*direction.x-sin(angle)*direction.y < 0 ? -1.0 : 1.0
        let normal = CGPoint(x: -direction.y*side, y: direction.x*side)
        let center = CGPoint(x: (start.x+end.x)*0.5, y: (start.y+end.y)*0.5)
        let arc = clamp(distance*c.arcSize, 50, 520), flow = clamp(distance*c.arcFlow, 38, 440)
        for arcScale in [0.55, 0.8, 1.05] {
            for flowScale in [0.65, 1.0, 1.35] {
                for sign in [1.0, -1.0] {
                    let middle = add(add(center, normal, sign*arc*arcScale), heading, first*0.16)
                    result.append(.init(start: start, end: end, segments: [
                        .init(end: middle, control1: c1, control2: add(middle, direction, -flow*flowScale)),
                        .init(end: end, control1: add(middle, direction, flow*flowScale), control2: c2)
                    ], middle: middle))
                }
            }
        }
        return Array(result.prefix(c.candidateCount))
    }
    static func select(start: CGPoint, end: CGPoint, bounds: CGRect, configuration c: Configuration = .init()) -> Self {
        let distance = hypot(end.x-start.x, end.y-start.y)
        if distance <= c.straightDistance {
            let delta = CGPoint(x: end.x-start.x, y: end.y-start.y)
            return .init(start: start, end: end, segments: [.init(end: end,
                control1: add(start, delta, 1.0/3), control2: add(start, delta, 0.6666666666666666))], middle: nil)
        }
        let all = candidates(start: start, end: end, configuration: c)
        precondition(!all.isEmpty)
        let evaluated = all.map { path -> (Self, Metrics, Double) in
            let m = path.metrics(bounds: bounds, margin: c.margin)
            return (path, m, path.score(metrics: m, angle: c.angle))
        }
        let contained = evaluated.filter { $0.1.inBounds }
        let choices = contained.isEmpty ? evaluated : contained
        var selected = choices[0]
        for choice in choices.dropFirst() where choice.2 < selected.2 { selected = choice }
        return selected.0
    }
    /// Clamp progress and distribute it evenly across the segment count.
    func point(at progress: Double) -> CGPoint {
        let sample = sample(at: progress)
        return sample.point
    }
    func sample(at progress: Double) -> (point: CGPoint, tangent: CGPoint) {
        let p = progress >= 1 ? 1 : (progress >= 0 ? progress : 0)
        let scaled = p == 1 ? Double(segments.count-1) : p*Double(segments.count)
        let index = Int(scaled), t = p == 1 ? 1 : scaled-Double(index)
        return Self.cubic(start: index == 0 ? start : segments[index-1].end, segment: segments[index], t: t)
    }
    private static func cubic(start: CGPoint, segment: Segment, t: Double) -> (point: CGPoint, tangent: CGPoint) {
        let mt = 1-t, a = mt*(mt*mt), b = t*(mt*(mt*3)), c = t*(t*(mt*3)), d = t*(t*t)
        let point = CGPoint(x: start.x*a+segment.control1.x*b+segment.control2.x*c+segment.end.x*d,
            y: start.y*a+segment.control1.y*b+segment.control2.y*c+segment.end.y*d)
        let tangent = CGPoint(x: 3*mt*mt*(segment.control1.x-start.x)+6*mt*t*(segment.control2.x-segment.control1.x)+3*t*t*(segment.end.x-segment.control2.x),
            y: 3*mt*mt*(segment.control1.y-start.y)+6*mt*t*(segment.control2.y-segment.control1.y)+3*t*t*(segment.end.y-segment.control2.y))
        return (point, tangent)
    }
    /// Sample 24 points per segment and wrap heading deltas at ±pi.
    func metrics(bounds: CGRect, margin: Double) -> Metrics {
        let inset = bounds.insetBy(dx: margin, dy: margin)
        var inside = inset.contains(start), previous = start, segmentStart = start
        var length = 0.0, squares = 0.0, maximum = 0.0, total = 0.0
        var heading: Double?
        for segment in segments {
            for step in 1...24 {
                let point = Self.cubic(start: segmentStart, segment: segment, t: Double(step)/24).point
                let dx = point.x-previous.x, dy = point.y-previous.y, distance = hypot(dx, dy)
                length += distance
                if inside { inside = inset.contains(point) }
                if distance > 0.01 {
                    let next = atan2(dy, dx)
                    if let heading {
                        var turn = next-heading
                        while turn > .pi { turn -= 2 * .pi }
                        while turn < -.pi { turn += 2 * .pi }
                        squares += turn*turn; maximum = max(maximum, abs(turn)); total += abs(turn)
                    }
                    heading = next
                }
                previous = point
            }
            segmentStart = segment.end
        }
        return .init(length: length, squaredTurns: squares, maximumTurn: maximum, totalTurn: total, inBounds: inside)
    }
    private func opposition(angle: Double) -> Double {
        let direction = Self.unit(CGPoint(x: end.x-start.x, y: end.y-start.y)), radians = angle * .pi / 180
        return Self.clamp((-0.08-(sin(radians)*direction.x+cos(radians)*direction.y))/0.92, 0, 1)
    }
    func score(metrics m: Metrics, angle: Double = -44) -> Double {
        let direct = hypot(end.x-start.x, end.y-start.y)
        let extra = max(0, m.length/max(direct, 1)-1)
        return m.length+extra*320+m.squaredTurns*140+m.maximumTurn*180+m.totalTurn*18+opposition(angle: angle)*90+(middle == nil ? 0 : 45)
    }
    /// Path response score from the sampled metrics.
    func response(metrics m: Metrics, configuration c: Configuration = .init()) -> Double {
        let direct = hypot(end.x-start.x, end.y-start.y)
        let distance = Self.clamp((m.length-180)/760, 0, 1)
        let excess = Self.clamp(max(0, m.length/max(direct, 1)-1)/0.55, 0, 1)
        let turn = Self.clamp(m.totalTurn/4.39822971502571, 0, 1)
        let squares = Self.clamp(m.squaredTurns/1.25, 0, 1)
        let complexity = Self.clamp(excess*0.42+turn*0.38+squares*0.2, 0, 1)
        let raw = opposition(angle: c.angle)*0.28+(distance*0.22+0.42)+complexity*0.12+(middle == nil ? 0 : 0.04)
        return Self.clamp(c.responseScale*raw*(middle == nil ? 1 : 0.9), c.minimumResponse, c.maximumResponse)
    }
}
