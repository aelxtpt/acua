import Foundation

enum ActionAppSnapshotURLPolicy {
    @MainActor private static let policy = EventStreamRecordingURLPolicy.local()

    static func check(_ text: String?, for app: ResolvedApp) throws {
        guard let text, let url = URL(string: text), url.host != nil,
              url.scheme == "http" || url.scheme == "https",
              let bundleURL = app.running.bundleURL, let bundle = Bundle(url: bundleURL),
              EventStreamBundleShape.isWebShaped(read: bundle.object(forInfoDictionaryKey:)) else { return }
        let pending = PendingResult<Bool>(discard: { _ in })
        let task = Task { @MainActor in
            pending.complete(.success(await policy.isURLBlocked(url)))
        }
        defer { task.cancel(); pending.abandon() }
        try RequestRuntime.wait(for: pending.signal, maximumSeconds: 120)
        if try pending.take() {
            let safeURL = EventStreamURLPolicyRecordFilter.normalizedURLString(url)
            throw ServiceError(.blockedURL, "Computer Use stopped due to encountering a disallowed URL: \(safeURL)")
        }
    }
}
