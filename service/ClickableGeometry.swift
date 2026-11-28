import Foundation
import CoreGraphics

enum ClickableGeometry {
    static func valid(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height, frame.maxX, frame.maxY].allSatisfy(\.isFinite) &&
        frame.width > 0 && frame.height > 0 && !frame.isNull && !frame.isInfinite
    }

    /// The generic path returns the element's center only when it is
    /// inside every clipping ancestor. It does not click a clipped-out center.
    static func point(frame: CGRect, clips: [CGRect], displays: [CGRect]? = nil) -> CGPoint? {
        guard valid(frame), clips.allSatisfy(valid) else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard center.x.isFinite, center.y.isFinite, clips.allSatisfy({ $0.contains(center) }) else { return nil }
        if let displays, !displays.contains(where: { valid($0) && $0.contains(center) }) { return nil }
        return center
    }

    static func clips(role: String, actions: [String]) -> Bool {
        if ["AXWindow", "AXSheet", "AXMenu", "AXPopover", "AXScrollArea"].contains(role) { return true }
        // Only these four exact page actions count. Merely
        // supporting AXScrollToVisible does not make a group clip children.
        let pageActions: Set<String> = ["AXScrollLeftByPage", "AXScrollRightByPage", "AXScrollUpByPage", "AXScrollDownByPage"]
        return role == "AXGroup" && actions.contains(where: pageActions.contains)
    }
    static func boundary(role: String) -> Bool { ["AXWindow", "AXSheet", "AXMenu", "AXPopover"].contains(role) }

    /// Whether a control's center lies outside its window. Some apps (GPUI
    /// apps, for example) expose no scroll areas and do not handle
    /// AXScrollToVisible, so a control scrolled out of a list keeps a frame
    /// outside the window, and pressing it presses nothing or something else.
    static func centerOutside(_ frame: CGRect, window: CGRect) -> Bool {
        guard valid(frame), valid(window) else { return false }
        return !window.contains(CGPoint(x: frame.midX, y: frame.midY))
    }
    /// The center of what the clipping frames leave of a frame, or nil when
    /// nothing of it is left.
    static func visiblePartCenter(frame: CGRect, clips: [CGRect]) -> CGPoint? {
        guard valid(frame) else { return nil }
        var visible = frame
        for clip in clips {
            guard valid(clip) else { return nil }
            visible = visible.intersection(clip)
        }
        guard valid(visible) else { return nil }
        return CGPoint(x: visible.midX, y: visible.midY)
    }

    static let offscreenClickMessage = "The element is outside the visible part of its window (scrolled out of view), and "
        + "the app offers no way to scroll it into view, so a click would land somewhere else or nowhere. Scroll its list "
        + "first, with `scroll` at an element of that list that is visible or at a coordinate inside the list, then call "
        + "`get_app_state` again."
    static let offscreenScrollMessage = "The element is outside the visible part of its window, so a scroll at it would "
        + "land somewhere else. Scroll at an element of the same list that is visible, or at a coordinate inside the list."

    static func isChessSquareTitle(_ title: String?) -> Bool {
        guard let title, let file = title.dropLast().last, let rank = title.last else { return false }
        return "abcdefgh".contains(file) && "12345678".contains(rank)
    }

    // Use the mean of the matching 64 × 64 cell centers.
    static func chessSquarePoint(frame: CGRect, parentFrame: () -> CGRect?,
                                 matches: (CGPoint) throws -> Bool?) rethrows -> CGPoint? {
        guard valid(frame), try matches(CGPoint(x: frame.midX, y: frame.midY)) == false,
              let board = parentFrame(), valid(board) else { return nil }
        let width = board.width / 64, height = board.height / 64
        var sum = CGPoint.zero
        var count: CGFloat = 0
        for row in 0..<64 {
            let y = board.minY + (CGFloat(row) + 0.5) * height
            for column in 0..<64 {
                let x = board.minX + (CGFloat(column) + 0.5) * width
                if try matches(CGPoint(x: x, y: y)) == true {
                    sum.x += x
                    sum.y += y
                    count += 1
                }
            }
        }
        return count > 0 ? CGPoint(x: sum.x / count, y: sum.y / count) : nil
    }

    /// Center a smaller target, align an oversized target, then
    /// convert the requested offset into the scrollbar's normalized value.
    static func scrollValue(targetMin: CGFloat, targetMax: CGFloat, visibleMin: CGFloat, visibleMax: CGFloat,
                            contentMin: CGFloat, contentMax: CGFloat, value: CGFloat?) -> CGFloat? {
        guard [targetMin, targetMax, visibleMin, visibleMax, contentMin, contentMax].allSatisfy(\.isFinite),
              targetMax > targetMin, visibleMax > visibleMin, contentMax > contentMin,
              value?.isFinite ?? true else { return nil }
        if targetMin >= visibleMin && targetMax <= visibleMax { return nil }
        let extent = (contentMax - contentMin) - (visibleMax - visibleMin)
        guard extent.isFinite, extent > 0 else { return nil }
        let delta: CGFloat
        if targetMax - targetMin <= visibleMax - visibleMin {
            delta = (targetMin - visibleMin + targetMax - visibleMax) * 0.5
        } else if targetMin < visibleMin { delta = targetMin - visibleMin }
        else { delta = targetMax - visibleMax }
        let current = value.map { min(1, max(0, $0)) * extent } ?? min(extent, max(0, visibleMin - contentMin))
        let result = min(extent, max(0, current + delta)) / extent
        return result.isFinite ? result : nil
    }
}
