import Foundation

enum NativeCoordinateConversion {
    // The native IPC dispatcher converts screenshot coordinates to Int64
    // before applying controller scale/origin (0x10015E608). Keep truncation
    // toward zero; reject unrepresentable values instead of trapping the service.
    static func truncate(_ point: CGPoint) throws -> CGPoint {
        guard let x = Int64(exactly: Double(point.x).rounded(.towardZero)),
              let y = Int64(exactly: Double(point.y).rounded(.towardZero)) else {
            throw ServiceError(.unhandledEvent, "Coordinates exceed the native integer range")
        }
        return CGPoint(x: Double(x), y: Double(y))
    }
}
