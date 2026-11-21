import Foundation
import CoreGraphics

/// Order the app's AX windows
/// by WindowServer stacking order, then take the first frame containing the point.
enum MouseTargeting {
    // EventTargetingError values reach the generic error mapper as ordinal 5.
    // Keep the enum's description for both transports.
    enum Failure: Error {
        case noWindowsAvailable
        case windowNotFoundAtPosition(CGPoint)
    }
    struct Window: Equatable {
        let id: UInt32
        let pid: Int32
        let frame: CGRect
        let screenFrame: CGRect
        init(id: UInt32, pid: Int32, frame: CGRect, screenFrame: CGRect? = nil) {
            self.id = id; self.pid = pid; self.frame = frame; self.screenFrame = screenFrame ?? frame
        }
        var pointer: PointerTarget { PointerTarget(windowID: id, ownerPID: pid, screenFrame: screenFrame) }
    }
    enum ProcessKind: Equatable { case application, service, unavailable }

    /// AX/CG use a top-left origin; NSWindow's mouse hit test uses AppKit's
    /// primary-screen bottom-left origin. Keep that origin across all displays.
    static func appKitPoint(from point: CGPoint, screenFrames: [CGRect]) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, let primary = screenFrames.first,
              CaptureLayout.valid(primary) else { return nil }
        let converted = CGPoint(x: point.x, y: primary.maxY - point.y)
        guard converted.y.isFinite, screenFrames.contains(where: {
            CaptureLayout.valid($0) && converted.x >= $0.minX && converted.x < $0.maxX &&
                converted.y > $0.minY && converted.y <= $0.maxY
        }) else { return nil }
        return converted
    }

    /// Only ask SystemWide when the mouse-hit window
    /// agrees with the selected app window. A nil hit preserves the app result;
    /// an actual hit must resolve successfully instead of falling back on error.
    static func refine<T, Hit>(provisional: T, selectedWindowID: UInt32, frontWindowID: UInt32?,
                               hitTest: () throws -> Hit?, resolve: (Hit) throws -> T) throws -> T {
        guard selectedWindowID != 0, frontWindowID == selectedWindowID else { return provisional }
        guard let hit = try hitTest() else { return provisional }
        return try resolve(hit)
    }

    static func select(at point: CGPoint, orderedIDs: [UInt32], windows: [Window], nativeErrors: Bool = false) throws -> Window {
        if !nativeErrors, !point.x.isFinite || !point.y.isFinite { throw ServiceError(.unhandledEvent, "Invalid pointer position") }
        var byID: [UInt32: Window] = [:]
        for window in windows {
            guard window.id != 0, window.pid > 0, CaptureLayout.valid(window.frame) else { continue }
            if let previous = byID[window.id], previous != window {
                throw ServiceError(.accessibilityError, "Conflicting accessibility window identities")
            }
            byID[window.id] = window
        }
        for id in orderedIDs {
            if let window = byID[id], window.frame.contains(point) { return window }
        }
        if nativeErrors { throw Failure.windowNotFoundAtPosition(point) }
        throw ServiceError(.accessibilityError, "No onscreen app window contains the pointer position")
    }

    /// Stop at the first finished app/service in the ancestry.
    /// Only a prohibited (view-service) process different from the host is remote.
    static func remotePID(hostPID: Int32, ancestry: [(pid: Int32, kind: ProcessKind)]) -> Int32? {
        for entry in ancestry where entry.pid > 0 {
            switch entry.kind {
            case .unavailable: continue
            case .application: return nil
            case .service: return entry.pid == hostPID ? nil : entry.pid
            }
        }
        return nil
    }
}
