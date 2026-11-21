import Foundation
import System

extension ControllerTemporaryImage {
    static func adoptingNative(_ url: URL, filePath:FilePath?=nil, log: @escaping @Sendable (String, any Error) -> Void) -> ControllerTemporaryImage {
        let path=filePath ?? FilePath(url.path(percentEncoded:false))
        return .init(adopting: url, identity:path, cleanup: { file in
            // The legacy helper discarded removeItem errors. Drop its tracking
            // entry separately so ARC deletion can report the real failure.
            NativeAppSnapshotImage.relinquishOwnership(file)
            try FileManager.default.removeItem(atPath:path.string)
        }, failed: { log("temporary screenshot cleanup", $0) })
    }
}
