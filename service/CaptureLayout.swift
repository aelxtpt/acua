import Foundation
import CoreGraphics

/// Geometry of a multi-window screenshot.
/// The first requested window anchors the crop; unrelated windows never expand it.
struct CaptureLayout {
    struct Window { let id: UInt32; let frame: CGRect }
    struct NativeWindow {
        let id: UInt32
        let ownerPID: Int32
        let frame: CGRect
        let title: String?
        let layer: Int
    }
    struct Display { let id: UInt32; let frame: CGRect }
    let windowIDs: [UInt32]
    let screenFrame: CGRect
    let displayID: UInt32?
    let sourceRect: CGRect?

    static func valid(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.width, frame.height, frame.maxX, frame.maxY].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0 && !frame.isNull
    }

    static func needsFullWindowList(requestedIDs: [UInt32], onscreenIDs: Set<UInt32>) -> Bool {
        requestedIDs.contains { !onscreenIDs.contains($0) }
    }

    static func bestDisplayIndex(for frame: CGRect, displayFrames: [CGRect]) -> Int? {
        var best: Int?, bestArea: CGFloat = -1
        for (index, display) in displayFrames.enumerated() where valid(display) {
            let intersection = display.intersection(frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea { best = index; bestArea = area }
        }
        return best
    }

    /// An `NSScreen` frame (AppKit: origin at the primary screen's bottom-left,
    /// y up) in WindowServer coordinates (origin at its top-left, y down).
    static func windowServerFrame(ofScreen appKitFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: appKitFrame.minX, y: primaryHeight - appKitFrame.maxY, width: appKitFrame.width, height: appKitFrame.height)
    }

    /// The screen showing most of a WindowServer-space window frame.
    /// `appKitScreenFrames` is `NSScreen.screens.map(\.frame)`, primary first.
    ///
    /// The screen frames are converted to WindowServer space first. Comparing
    /// the WindowServer frame directly with the AppKit screen frames fails on a
    /// display above or below the primary: the two spaces disagree, the window
    /// matches no screen, and the primary's scale would size a capture of
    /// another display.
    static func screenIndex(for windowServerWindowFrame: CGRect, appKitScreenFrames: [CGRect]) -> Int? {
        guard let primary = appKitScreenFrames.first else { return nil }

        let converted = appKitScreenFrames.map { windowServerFrame(ofScreen: $0, primaryHeight: primary.maxY) }
        return bestDisplayIndex(for: windowServerWindowFrame, displayFrames: converted)
    }

    // Use the first exact PID/frame match, filtering by
    // concrete title only when the frame identifies multiple windows.
    static func matchNativeWindow(pid: Int32, frame: CGRect, title: String?,
                                  windows: [NativeWindow], servicePID: Int32, menuLevel: Int) -> NativeWindow? {
        guard pid > 0, pid != servicePID, valid(frame) else { return nil }
        let matches = windows.filter { $0.id != 0 && $0.ownerPID == pid && $0.layer < menuLevel && $0.frame == frame }
        if matches.count == 1 { return matches.first }
        guard let title else { return nil }
        return matches.first { $0.title == title }
    }

    // Select the Finder's first WindowServer desktop-icon window.
    static func finderDesktopWindow(pid: Int32, desktopIconLevel: Int, windows: [NativeWindow]) -> NativeWindow? {
        guard pid > 0 else { return nil }
        return windows.first { $0.ownerPID == pid && $0.layer == desktopIconLevel && $0.id != 0 && valid($0.frame) }
    }

    static func make(primaryID: UInt32, additionalIDs: [UInt32], windows: [Window], displays: [Display],
                     useDisplayForAdditionalWindows: Bool = true) throws -> Self {
        var available: [UInt32: Window] = [:]
        for window in windows {
            guard available[window.id] == nil else { throw ServiceError(.accessibilityError, "Duplicate capture window identifier") }
            available[window.id] = window
        }
        guard primaryID != 0, let primary = available[primaryID], valid(primary.frame) else {
            throw ServiceError(.accessibilityError, "Primary capture window is unavailable")
        }
        var ids = [primaryID], seen: Set<UInt32> = [primaryID]
        for id in additionalIDs where id != 0 && seen.insert(id).inserted {
            // Missing SCWindows are compacted away. A hidden cursor is optional;
            // a missing primary must never silently select another window.
            if let window = available[id], valid(window.frame) { ids.append(id) }
        }
        guard useDisplayForAdditionalWindows, !additionalIDs.isEmpty else {
            return Self(windowIDs: ids, screenFrame: primary.frame, displayID: nil, sourceRect: nil)
        }
        guard let index = bestDisplayIndex(for: primary.frame, displayFrames: displays.map(\.frame)) else {
            throw ServiceError(.accessibilityError, "No display is available for multi-window capture")
        }
        let display = displays[index]
        return Self(windowIDs: ids, screenFrame: primary.frame, displayID: display.id,
                    sourceRect: primary.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY))
    }
}
