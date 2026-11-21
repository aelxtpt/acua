import Foundation

// IPC scroll continuations and distance helper. Extents are in global
// points, independent of image scale.
enum NativeScroll {
    enum Direction: UInt8 {
        case up, down, left, right
        init?(_ value: String) {
            switch value {
            case "up": self = .up
            case "down": self = .down
            case "left": self = .left
            case "right": self = .right
            default: return nil
            }
        }
    }

    static func validate(pages: Double) throws {
        guard pages > 0 else { throw ServiceError(.unknownError, "invalidScrollPages") }
    }

    static func delta(direction: Direction, pages: Double, extent: Double) throws -> (x: Int64, y: Int64) {
        guard let distance = Int64(exactly: (pages * extent).rounded(.toNearestOrAwayFromZero)),
              distance != Int64.min || (direction != .down && direction != .left) else {
            // Unrepresentable arithmetic becomes a controlled request failure
            // instead of a trap.
            throw ServiceError(.unhandledEvent, "Scroll distance exceeds the native integer range")
        }
        switch direction {
        case .up: return (0, distance)
        case .down: return (0, -distance)
        case .left: return (-distance, 0)
        case .right: return (distance, 0)
        }
    }

    static func delta(direction: Direction, pages: Double, size: CGSize) throws -> (x: Int64, y: Int64) {
        let extent = Double(direction == .up || direction == .down ? size.height : size.width)
        return try delta(direction: direction, pages: pages, extent: extent > 100 ? extent : 100)
    }
}
