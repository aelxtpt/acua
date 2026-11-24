import Foundation

/// One way to encode a screenshot.
enum AcuaScreenshotEncodingAttempt: Hashable, Sendable {
    case png
    case jpeg(quality: Double)
}

/// Keeps a screenshot within `[screenshots].max_image_bytes`. Only the
/// encoding changes, never the pixel size, so the coordinates the agent reads
/// from the image stay valid.
enum AcuaScreenshotBudget {
    /// JPEG qualities tried, in order, after the configured encoding is over
    /// the limit. Below 0.25, text in the screenshot stops being readable.
    static let fallbackJPEGQualities = [0.6, 0.4, 0.25]

    struct Written<File> {
        let file: File
        let attempt: AcuaScreenshotEncodingAttempt
        let byteCount: Int
        let withinLimit: Bool
    }

    /// The configured encoding first. With a limit, a PNG falls back to JPEG
    /// at the configured quality, then JPEG steps down, never above the
    /// configured quality.
    static func attempts(for configuration: AcuaScreenshotConfiguration) -> [AcuaScreenshotEncodingAttempt] {
        let configured: AcuaScreenshotEncodingAttempt = configuration.format == .png
            ? .png
            : .jpeg(quality: configuration.jpegQuality)
        guard configuration.maxImageBytes > 0 else { return [configured] }

        var attempts = [configured]
        if configuration.format == .png {
            attempts.append(.jpeg(quality: configuration.jpegQuality))
        }
        attempts += fallbackJPEGQualities.filter { $0 < configuration.jpegQuality }.map { .jpeg(quality: $0) }
        return attempts
    }

    /// Writes each attempt until one fits, discarding the rejected files. When
    /// none fits, the last (smallest) one is kept and marked over the limit:
    /// an agent still gets an image, and the result may be refused by a
    /// client with a lower limit instead of failing here.
    static func write<File>(_ attempts: [AcuaScreenshotEncodingAttempt], maxBytes: Int,
                            write: (AcuaScreenshotEncodingAttempt) throws -> (File, Int),
                            discard: (File) -> Void) throws -> Written<File> {
        precondition(!attempts.isEmpty, "at least the configured encoding is attempted")

        for (index, attempt) in attempts.enumerated() {
            let (file, byteCount) = try write(attempt)
            let withinLimit = maxBytes == 0 || byteCount <= maxBytes
            let isLast = index == attempts.count - 1

            if withinLimit || isLast {
                return Written(file: file, attempt: attempt, byteCount: byteCount, withinLimit: withinLimit)
            }
            discard(file)
        }

        // The loop returns on its last element.
        preconditionFailure("unreachable")
    }
}
