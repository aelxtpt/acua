import CoreGraphics
import Foundation

/// CGWindow description row. The mandatory ID traps on malformed rows;
/// optional fields keep their default values.
struct ControllerWindowDescription: Sendable, Equatable {
    let id: UInt32
    let ownerPID: Int32
    let bounds: CGRect
    let level: Int32
    let name: String?
    let ownerName: String?
    let isOnscreen: Bool?

    init(info: [AnyHashable: Any]) {
        id = info[kCGWindowNumber as String]! as! UInt32
        ownerPID = info[kCGWindowOwnerPID as String] as? Int32 ?? -1
        if let dictionary = info[kCGWindowBounds as String] as? NSDictionary {
            bounds = CGRect(dictionaryRepresentation: dictionary) ?? .zero
        } else { bounds = .zero }
        level = info[kCGWindowLayer as String] as? Int32 ?? 0
        name = info[kCGWindowName as String] as? String
        ownerName = info[kCGWindowOwnerName as String] as? String
        isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool
    }

    /// Select the first row, without requiring its ID to match the request.
    static func lookup(_ id: UInt32, request: (CFArray) -> CFArray? = CGWindowListCreateDescriptionFromArray) -> Self? {
        guard id != 0 else { return nil }
        var value = UnsafeRawPointer(bitPattern: UInt(id))
        let ids = CFArrayCreate(nil, &value, 1, nil)!
        guard let rows = request(ids) as? [[AnyHashable: Any]], let first = rows.first else { return nil }
        return Self(info: first)
    }
}
