import Foundation
import System

/// The screenshot keeps this same reference as the owner's set. Like
/// SlimCore.TemporaryFile, deletion occurs when its last reference is released.
final class ControllerTemporaryImage: Hashable, Sendable {
    let url: URL
    private let pathIdentity: FilePath
    private let cleanup: @Sendable (URL) throws -> Void
    private let failed: @Sendable (any Error) -> Void
    init(adopting url: URL, identity:FilePath?=nil, cleanup: @escaping @Sendable (URL) throws -> Void,
         failed: @escaping @Sendable (any Error) -> Void) {
        self.url = url; pathIdentity = identity ?? FilePath(url.path(percentEncoded: false))
        self.cleanup = cleanup; self.failed = failed
    }
    static func == (lhs: ControllerTemporaryImage, rhs: ControllerTemporaryImage) -> Bool { lhs.pathIdentity == rhs.pathIdentity }
    func hash(into hasher: inout Hasher) { hasher.combine(pathIdentity) }
    deinit { do { try cleanup(url) } catch { failed(error) } }
}
