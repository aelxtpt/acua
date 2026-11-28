import CoreGraphics
import Foundation

// Unit tests for telling a screenshot that was not redrawn from one that was:
// an app whose window is hidden behind other windows can keep returning its
// last picture while its accessibility tree moves on. Pictures are synthetic
// pixel buffers of the window alone, as the service fingerprints them.

@main
enum AcuaScreenshotStalenessTests {
    nonisolated(unsafe) private static var passed = 0

    // -O strips precondition messages, so a failure names itself and exits.
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        guard condition else {
            print("FAIL \(name) \(detail())")
            exit(1)
        }

        passed += 1
        print("PASS \(name)")
    }

    /// A grey picture, 4 bytes per pixel, with every rectangle in `painted`
    /// filled with its own value. Row padding is filled with noise, because it
    /// is not part of the picture.
    private static func picture(width: Int = 200, height: Int = 120, rowPadding: Int = 0,
                                painted: [(CGRect, UInt8)] = []) -> ControllerScreenshotFingerprint? {
        let bytesPerRow = width * 4 + rowPadding
        var bytes = [UInt8](repeating: 0x40, count: bytesPerRow * height)
        for y in 0..<height { for x in 0..<rowPadding { bytes[y * bytesPerRow + width * 4 + x] = UInt8(truncatingIfNeeded: x &* 37 &+ y) } }
        for (rect, value) in painted {
            for y in max(0, Int(rect.minY))..<min(height, Int(rect.maxY)) {
                for x in max(0, Int(rect.minX))..<min(width, Int(rect.maxX)) {
                    for channel in 0..<4 { bytes[y * bytesPerRow + x * 4 + channel] = value }
                }
            }
        }
        return bytes.withUnsafeBytes {
            ControllerScreenshotFingerprint(bytes: $0, width: width, height: height, bytesPerRow: bytesPerRow, bytesPerPixel: 4)
        }
    }

    private static func evidence(_ fingerprint: ControllerScreenshotFingerprint?, tree: String) -> ControllerScreenshotEvidence {
        .init(fingerprint: fingerprint!, tree: tree)
    }

    static func main() {
        let plain = picture()
        check("Fingerprint_SamePixels_AreEqual", plain != nil && plain == picture())
        check("Fingerprint_RowPadding_IsNotPartOfThePicture", plain?.hashes == picture(rowPadding: 12)?.hashes)
        check("Fingerprint_CoversPartialBlocksAtTheEdges", plain?.columns == 7 && plain?.rows == 4 && plain?.hashes.count == 28,
              "\(String(describing: plain?.columns))x\(String(describing: plain?.rows))")
        check("Fingerprint_BufferTooShort_IsRejected", [UInt8](repeating: 0, count: 100).withUnsafeBytes {
            ControllerScreenshotFingerprint(bytes: $0, width: 200, height: 120, bytesPerRow: 800, bytesPerPixel: 4)
        } == nil)

        let lastCorner = picture(painted: [(CGRect(x: 196, y: 118, width: 4, height: 2), 0xFF)])
        check("Difference_OnePixelRunInTheLastBlock_IsSeen", plain?.differs(from: lastCorner!) == true)
        check("Difference_SamePicture_IsNotSeen", plain?.differs(from: picture()!) == false)
        check("Difference_DifferentSizes_CannotBeCompared", plain?.differs(from: picture(width: 220)!) == nil)

        let closed = "0 window\n\t1 button Label", open = "0 window\n\t1 button Label\n\t2 text field Search"
        // A button that changes when clicked: a small change, right where the
        // Agent cursor stands in the picture sent to the agent.
        let toggled = picture(painted: [(CGRect(x: 150, y: 20, width: 30, height: 12), 0x90)])
        let popover = picture(painted: [(CGRect(x: 60, y: 30, width: 100, height: 70), 0xA0)])

        // The case from the report: a click opened a popover, the tree shows
        // it, and the picture is still the one from before the click.
        var hidden = ControllerScreenshotStalenessTracker()
        check("Stale_FirstSnapshot_IsNotReported", !hidden.isStale(evidence(plain, tree: closed)))
        check("Stale_TreeChangedPictureDidNot_IsReported", hidden.isStale(evidence(plain, tree: open)))
        check("Stale_SamePictureOnTheNextRead_IsStillReported", hidden.isStale(evidence(plain, tree: open)))
        check("Stale_TreeBackToThePictures_IsNotReported", !hidden.isStale(evidence(plain, tree: closed)))
        check("Stale_PictureRedrawnLater_IsNotReported", !hidden.isStale(evidence(popover, tree: open)))
        check("Stale_RedrawnPictureBecomesTheReference", hidden.reference?.tree == open)

        // Seen live: a click changed only the button under the cursor. The
        // fingerprint is taken without the cursor, so the change is seen.
        var drawn = ControllerScreenshotStalenessTracker()
        _ = drawn.isStale(evidence(plain, tree: closed))
        check("Stale_SmallChangeUnderTheCursor_IsNotReported", !drawn.isStale(evidence(toggled, tree: open)))
        check("Stale_NothingChanged_IsNotReported", !drawn.isStale(evidence(toggled, tree: open)))
        check("Stale_WindowResized_IsNotReported", !drawn.isStale(evidence(picture(width: 220), tree: closed)))

        print("\(passed) screenshot staleness tests passed")
    }
}
