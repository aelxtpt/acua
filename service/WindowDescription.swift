import CoreGraphics
import Foundation

enum WindowDescription {
    static func lookup(_ windowID: CGWindowID) -> [String: Any]? {
        guard windowID != kCGNullWindowID else { return nil }
        // Look up a single window with raw IDs and nil object callbacks. This API also describes hosted
        // backing windows absent from ordinary composited-window enumeration.
        var value = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard let ids = CFArrayCreate(nil, &value, 1, nil),
              let windows = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]] else { return nil }
        return windows.first(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID })
    }
}
