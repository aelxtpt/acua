import Darwin
import Foundation
import ImageIO
import OSLog
import System
import UniformTypeIdentifiers

enum NativeAppSnapshotImage {
    typealias Encoding=ControllerScreenshotEncoding

    struct Settings {
        let legacySizing: Bool
        let normalizeToPoints: Bool
        let encoding: Encoding
        /// Encodings tried in order to stay within `maxImageBytes`; empty
        /// means `encoding` alone.
        var attempts: [AcuaScreenshotEncodingAttempt] = []
        /// 0 means no limit.
        var maxImageBytes = 0

        /// `[screenshots].resolution` chooses the sizing. "fit" turns on the
        /// legacy fitted, point-normalized sizing; otherwise every Retina
        /// pixel is sent.
        static func current() -> Self {
            let screenshots = AcuaSettings.screenshots()
            let attempts = AcuaScreenshotBudget.attempts(for: screenshots)
            return .init(legacySizing: screenshots.resolution == .fit, normalizeToPoints: true,
                encoding: NativeAppSnapshotImage.encoding(attempts[0]), attempts: attempts,
                maxImageBytes: screenshots.maxImageBytes)
        }

        func sizing(backingScale: CGFloat) -> ScreenshotGeometry.Sizing {
            guard legacySizing else { return .native }
            return normalizeToPoints && backingScale > 1 ? .points : .legacy
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var owned = Set<URL>()
    nonisolated(unsafe) private static var directory:URL={
        let path=FilePath(NSTemporaryDirectory()).appending(Bundle.main.bundleIdentifier ?? "inc.software.unknown")
        try? ControllerScreenshotPaths.ensureDirectory(path)
        return URL(filePath:path.string,directoryHint:.isDirectory)
    }()
    static var defaultDirectory:URL {
        get{lock.withLock{directory}}
        set{lock.withLock{directory=newValue}}
    }

    static func encoding(useJPEG: Bool, quality: Double) -> Encoding {
        guard useJPEG else { return .png }
        return .jpeg(quality > 0 && quality <= 1 ? CGFloat(quality) : nil)
    }

    static func encoding(_ attempt: AcuaScreenshotEncodingAttempt) -> Encoding {
        switch attempt {
        case .png: return encoding(useJPEG: false, quality: 0)
        case .jpeg(let quality): return encoding(useJPEG: true, quality: quality)
        }
    }

    private static let logger = Logger(subsystem: "com.aex.computeruse", category: "Screenshots")

    /// Writes the image with the first of `settings.attempts` that fits
    /// `settings.maxImageBytes`, and returns the encoding used so the reply
    /// names the right MIME type.
    static func writeFileWithinBudget(_ image: CGImage, appName: String?, directory: URL,
                                      settings: Settings) throws -> (file: ControllerScreenshotWrittenFile, encoding: Encoding) {
        guard !settings.attempts.isEmpty else {
            return (try writeFile(image, appName: appName, directory: directory, encoding: settings.encoding), settings.encoding)
        }

        let written = try AcuaScreenshotBudget.write(settings.attempts, maxBytes: settings.maxImageBytes, write: { attempt in
            let file = try writeFile(image, appName: appName, directory: directory, encoding: encoding(attempt))
            let byteCount = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int) ?? 0
            return (file, byteCount)
        }, discard: { file in
            _ = removeIfOwned(file.url)
        })

        if !written.withinLimit {
            logger.error("Screenshot of \(image.width)x\(image.height) is \(written.byteCount) bytes, over max_image_bytes \(settings.maxImageBytes) even at the lowest quality")
        }
        return (written.file, encoding(written.attempt))
    }

    static func write(_ image:CGImage,appName:String?,directory:URL,date:Date=Date(),encoding:Encoding)throws->URL {
        try writeFile(image,appName:appName,directory:directory,date:date,encoding:encoding).url
    }
    static func writeFile(_ image:CGImage,appName:String?,directory:URL,date:Date=Date(),encoding:Encoding)throws->ControllerScreenshotWrittenFile {
        let writer = ControllerScreenshotFileWriter<ControllerScreenshotAtomicDestination>(environment: .init(
            paths: .init(exists: { path in
                var info = stat()
                return lstat(path, &info) == 0
            }, ensureDirectory: { path in
                try FileManager.default.createDirectory(atPath: path.string, withIntermediateDirectories: true)
            }),
            create: { ControllerScreenshotAtomicDestination.make($0, encoding: $1) },
            addAndFinalize: { destination, image, encoding in
                try destination.finalize(image, encoding: encoding)
                return true
            },
            register: { url in lock.withLock { _ = owned.insert(url) } }
        ))
        // Two captures can select the same filename before either one publishes.
        // The exclusive rename leaves the first capture intact; retry its path selection.
        for _ in 0..<128 {
            do {
                return try writer.writeFile(image, appName: appName, directory: directory, date: date, encoding: encoding)
            } catch let error as ControllerScreenshotAtomicDestination.PublicationError where error == .collision {
                continue
            }
        }
        throw POSIXError(.EEXIST)
    }

    static func relinquishOwnership(_ file: URL) {
        lock.withLock { _ = owned.remove(file) }
    }

    static func removeIfOwned(_ file: URL) -> Bool {
        guard lock.withLock({ owned.remove(file) != nil }) else { return false }
        try? FileManager.default.removeItem(at: file)
        return true
    }

}
