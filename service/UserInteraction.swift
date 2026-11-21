import Foundation
import CoreGraphics

/// A user input event observed while a computer-use session runs.
/// Pointer motion, key releases and modifier changes do not interrupt a session.
struct UserInteraction {
    static let eventTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
    static let mask = eventTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    let type: CGEventType
    let sourcePID: Int64
    let targetPID: Int64
    let windowID: Int64?

    func isExternal(to servicePID: Int32) -> Bool {
        Self.eventTypes.contains(type) && Int32(exactly: sourcePID) != nil && sourcePID != Int64(servicePID)
            && Int32(exactly: targetPID) != nil
    }

    func target(windowOwner: (CGWindowID) -> Int32?) -> Int32? {
        if let windowID, let id = UInt32(exactly: windowID), let owner = windowOwner(id), owner > 0 { return owner }
        guard let pid = Int32(exactly: targetPID), pid > 0 else { return nil }
        return pid
    }

    static func markSynthesized(_ event: CGEvent, servicePID: Int32 = getpid()) {
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(servicePID))
    }
}
