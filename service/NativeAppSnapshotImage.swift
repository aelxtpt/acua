import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NativeAppSnapshotImage {
    enum Encoding {
        case jpeg(CGFloat?)
        case png

        var type: UTType {
            switch self {
            case .jpeg: return .jpeg
            case .png: return .png
            }
        }
        var properties: CFDictionary? {
            guard case .jpeg(let quality?) = self else { return nil }
            return [kCGImageDestinationLossyCompressionQuality as String: quality] as CFDictionary
        }
    }

    struct Settings {
        let legacySizing: Bool
        let normalizeToPoints: Bool
        let encoding: Encoding

        /// Fixed defaults: the legacy sizing path stays off and sizes are
        /// normalized to points; the encoding comes from `[screenshots]` settings.
        static func current() -> Self {
            let screenshots = AcuaSettings.screenshots()
            return Self(legacySizing: false, normalizeToPoints: true,
                        encoding: NativeAppSnapshotImage.encoding(useJPEG: screenshots.format == .jpeg,
                                                             quality: screenshots.jpegQuality))
        }

        func sizing(backingScale: CGFloat) -> ScreenshotGeometry.Sizing {
            guard legacySizing else { return .native }
            return normalizeToPoints && backingScale > 1 ? .points : .legacy
        }
    }

    private static let lock = NSLock()
    private static var owned = Set<URL>()
    private static let dateFormatters: (DateFormatter, DateFormatter) = {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.dateFormat = "h.mm.ss a"
        return (day, time)
    }()

    static var defaultDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.aex.computeruse.unknown", isDirectory: true)
    }

    static func encoding(useJPEG: Bool, quality: Double) -> Encoding {
        guard useJPEG else { return .png }
        return .jpeg(quality > 0 && quality <= 1 ? CGFloat(quality) : nil)
    }

    static func write(_ image: CGImage, appName: String, directory: URL, date: Date = Date(), encoding: Encoding) throws -> URL {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, encoding.type.identifier as CFString, 1, nil) else {
            throw ServiceError(.unknownError, "Failed to create screenshot destination")
        }
        CGImageDestinationAddImage(destination, image, encoding.properties)
        guard CGImageDestinationFinalize(destination) else {
            throw ServiceError(.unknownError, "Failed to encode screenshot")
        }
        let data = bytes as Data
        let name = filename(appName: appName, date: date, extension: encoding.type.preferredFilenameExtension ?? "")
        var collision = 0
        while true {
            try Task.checkCancellation()
            let parent = collision == 0 ? directory : directory.appendingPathComponent(String(collision), isDirectory: true)
            let file = parent.appendingPathComponent(name).standardizedFileURL
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                try data.write(to: file, options: .withoutOverwriting)
                lock.withLock { _ = owned.insert(file) }
                return file
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                collision += 1
            }
        }
    }

    static func removeIfOwned(_ file: URL) -> Bool {
        guard lock.withLock({ owned.remove(file) != nil }) else { return false }
        try? FileManager.default.removeItem(at: file)
        return true
    }

    private static func filename(appName: String, date: Date, extension ext: String) -> String {
        let suffix = lock.withLock {
            " \(dateFormatters.0.string(from: date)) at \(dateFormatters.1.string(from: date)).\(ext)"
        }
        // Reserve six units in the component budget and keep
        // complete characters within the filesystem's byte limit as well.
        var name = ""
        for character in appName.replacingOccurrences(of: "/", with: ":").replacingOccurrences(of: "\0", with: ":") {
            let candidate = name + String(character)
            guard candidate.utf16.count + suffix.utf16.count <= 249,
                  candidate.utf8.count + suffix.utf8.count <= 255 else { break }
            name = candidate
        }
        return name + suffix
    }
}
