import CoreGraphics
import Foundation

/// A coarse fingerprint of a captured window picture: one hash for each block
/// of pixels. It is taken from a capture of the window alone, without the
/// Agent cursor, so two captures of a window that was not redrawn in between
/// have the same hashes.
struct ControllerScreenshotFingerprint: Equatable, Sendable {
    static let blockSize = 32
    let width: Int
    let height: Int
    let hashes: [UInt64]
    var columns: Int { (width + Self.blockSize - 1) / Self.blockSize }
    var rows: Int { (height + Self.blockSize - 1) / Self.blockSize }

    init?(bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, bytesPerPixel: Int) {
        guard width > 0, height > 0, bytesPerPixel > 0, bytesPerRow >= width * bytesPerPixel,
              bytes.count >= (height - 1) * bytesPerRow + width * bytesPerPixel else { return nil }
        self.width = width; self.height = height
        let block = Self.blockSize
        let columns = (width + block - 1) / block, rows = (height + block - 1) / block
        // FNV-1a over the bytes of each block.
        var hashes = [UInt64](repeating: 0xcbf2_9ce4_8422_2325, count: columns * rows)
        for y in 0..<height {
            let row = y / block * columns, start = y * bytesPerRow
            for column in 0..<columns {
                let from = start + column * block * bytesPerPixel
                let to = start + min(width, (column + 1) * block) * bytesPerPixel
                var hash = hashes[row + column]
                for offset in from..<to { hash = (hash ^ UInt64(bytes[offset])) &* 0x0000_0100_0000_01b3 }
                hashes[row + column] = hash
            }
        }
        self.hashes = hashes
    }

    init?(_ image: CGImage) {
        guard image.bitsPerPixel % 8 == 0, let data = image.dataProvider?.data, let pointer = CFDataGetBytePtr(data) else { return nil }
        let bytes = UnsafeRawBufferPointer(start: pointer, count: CFDataGetLength(data))
        self.init(bytes: bytes, width: image.width, height: image.height, bytesPerRow: image.bytesPerRow,
                  bytesPerPixel: image.bitsPerPixel / 8)
    }

    /// Whether any block differs. Nil when the two pictures do not have the
    /// same size and cannot be compared.
    func differs(from other: Self) -> Bool? {
        guard width == other.width, height == other.height else { return nil }
        return hashes != other.hashes
    }
}

/// What one snapshot leaves behind for the next one to compare against.
struct ControllerScreenshotEvidence: Sendable {
    let fingerprint: ControllerScreenshotFingerprint
    /// The full accessibility tree as text, whatever the snapshot returned.
    let tree: String
}

/// Some apps stop drawing while their window is hidden behind other windows.
/// They still handle input and publish a new accessibility tree, and the
/// WindowServer keeps returning the last picture they drew. A changed tree
/// under an unchanged picture is the sign of it.
enum ControllerScreenshotStaleness {
    static let warning = "Warning: the accessibility tree changed but the screenshot still shows the earlier picture, so "
        + "it can be out of date. Apps that stop drawing while their window is hidden behind other windows (GPUI apps, "
        + "for example) do this. Rely on the tree, or ask the user to bring the app's window to the front."
}

/// Follows one window from snapshot to snapshot. The reference is the last
/// snapshot whose picture and tree were taken to agree. A later snapshot with
/// that same picture and another tree is stale, and stays stale until the
/// picture changes or the tree is back to the reference's.
struct ControllerScreenshotStalenessTracker: Sendable {
    private(set) var reference: ControllerScreenshotEvidence?

    mutating func isStale(_ current: ControllerScreenshotEvidence) -> Bool {
        guard let reference else { self.reference = current; return false }
        // A new picture, or one of another size, is a fresh picture.
        guard current.fingerprint.differs(from: reference.fingerprint) == false else {
            self.reference = current; return false
        }
        if current.tree == reference.tree { self.reference = current; return false }
        return true
    }
}
