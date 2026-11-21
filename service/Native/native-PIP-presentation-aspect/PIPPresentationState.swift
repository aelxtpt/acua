import Foundation
import CoreGraphics

/// There is one continuation; replacing
/// it resolves the previous waiter with the incoming fallback, not its old one.
@MainActor final class PIPPresentationState {
    typealias Sleep = @MainActor @Sendable (Duration) async throws -> Void
    private let sleep: Sleep
    private var continuation: CheckedContinuation<PIPPresentationAspect, Never>?
    private var timeout: Task<Void, Never>?
    private(set) var currentSize: CGSize?
    private(set) var latest: PIPPresentationAspect?
    private(set) var latestGeneration = 0
    var maximumDisplaySize: CGFloat = 200
    var hasPendingWaiter: Bool { continuation != nil }
    var hasTimeout: Bool { timeout != nil }

    init(sleep: @escaping Sleep = { try await ContinuousClock().sleep(for: $0) }) { self.sleep = sleep }

    func beginCapture(generation: Int) {
        latest = nil
        latestGeneration = generation
    }
    func record(_ aspect: PIPPresentationAspect, generation: Int) {
        latest = aspect
        latestGeneration = generation
        if continuation != nil || currentSize == nil {
            currentSize = aspect.size
            resolve(aspect)
        }
    }
    func resolve(_ aspect: PIPPresentationAspect) {
        guard let previous = continuation else { return }
        continuation = nil
        timeout?.cancel()
        timeout = nil
        currentSize = aspect.size
        previous.resume(returning: aspect)
    }
    func cancelTimeout() { timeout?.cancel(); timeout = nil }
    func resolveFallback(reason: String) {
        let size = currentSize ?? CGSize(width: 200, height: 200)
        resolve(.init(size: size, reason: reason, sourceSize: size))
    }
    func wait(fallback: PIPPresentationAspect, useCurrentCache: Bool, captureGeneration: Int) async -> PIPPresentationAspect {
        if useCurrentCache, let currentSize { return .init(size: currentSize, reason: "current-cache", sourceSize: currentSize) }
        if let latest, latestGeneration == captureGeneration {
            currentSize = latest.size
            return latest
        }
        return await withCheckedContinuation { next in
            resolve(fallback)
            continuation = next
            timeout?.cancel()
            let sleep = sleep
            timeout = Task { [weak self] in
                do { try await sleep(.milliseconds(500)) } catch { return }
                // No additional cancellation or generation guard: this resumes
                // after a successful clock wait and weak-owner lookup.
                self?.resolve(fallback)
            }
        }
    }
    @discardableResult
    func updateMaximum(_ maximum: CGFloat, targetBounds: CGRect?, captureGeneration: Int) -> CGSize {
        maximumDisplaySize = PIPPresentationAspectParser.normalizedMaximum(maximum)
        let source: CGSize
        if let latest, latestGeneration == captureGeneration { source = latest.sourceSize }
        else if let targetBounds { source = targetBounds.size }
        else { source = currentSize ?? CGSize(width: 200, height: 200) }
        let size = PIPPresentationAspectParser.fit(source, maximum: maximumDisplaySize)
        currentSize = size
        return size
    }
}
