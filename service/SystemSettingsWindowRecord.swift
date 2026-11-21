import Foundation
import CoreGraphics

/// A missing required window number traps; remaining malformed or
/// absent fields keep their defaults instead of discarding a row.
struct SystemSettingsWindowRecord: Sendable, Equatable {
    let identifier: UInt32
    let ownerPID: Int32
    let frame: CGRect
    let level: Int32
    let name: String?
    let ownerName: String?
    let isOnscreen: Bool?

    init(info: [String:Any]) {
        identifier=info[kCGWindowNumber as String]! as! UInt32
        ownerPID=info[kCGWindowOwnerPID as String] as? Int32 ?? -1
        if let dictionary=info[kCGWindowBounds as String] as? NSDictionary {
            frame=CGRect(dictionaryRepresentation:dictionary) ?? .zero
        } else { frame = .zero }
        level=info[kCGWindowLayer as String] as? Int32 ?? 0
        name=info[kCGWindowName as String] as? String
        ownerName=info[kCGWindowOwnerName as String] as? String
        isOnscreen=info[kCGWindowIsOnscreen as String] as? Bool
    }
    init(identifier: UInt32, ownerPID: Int32 = -1, frame: CGRect = .zero, level: Int32 = 0,
         name: String? = nil, ownerName: String? = nil, isOnscreen: Bool? = nil) {
        self.identifier=identifier;self.ownerPID=ownerPID;self.frame=frame;self.level=level
        self.name=name;self.ownerName=ownerName;self.isOnscreen=isOnscreen
    }
    static func decode(_ list: Any?) -> [Self] {
        guard let rows=list as? [[String:Any]] else { return [] }
        return rows.map { Self(info:$0) }
    }
    static func nativeWindows(ownerPID: Int32, onscreenOnly: Bool) -> [Self] {
        let options: CGWindowListOption=onscreenOnly ? [.optionOnScreenOnly,.excludeDesktopElements]:.excludeDesktopElements
        return decode(CGWindowListCopyWindowInfo(options,kCGNullWindowID)).filter { $0.ownerPID == ownerPID }
    }
    var qualifiesAsMainSettingsWindow: Bool { frame.width > 600 && frame.height >= 470 }
}
