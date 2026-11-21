import Foundation

struct EventStreamBlockedCaptureContext: Hashable {
    let application: EventStreamObservedApplication
    let normalizedURL: URL
    // The ID is the URL only, not application ID + URL.
    var id: String { normalizedURL.absoluteString }
}

enum EventStreamRecordDisposition: Equatable {
    case blocked(EventStreamBlockedCaptureContext)
    case include
}

@MainActor
protocol EventStreamRecordFilter {
    func disposition(for record: EventStreamRecord) async -> EventStreamRecordDisposition
}

// The policy backend is
// required: a missing native URL policy must not silently become "allow all".
@MainActor
final class EventStreamURLPolicyRecordFilter: EventStreamRecordFilter {
    private let isURLBlocked: (URL) async -> Bool
    private let isWebBrowser: (EventStreamApp) -> Bool
    private let resolveApplication: (EventStreamApp) -> EventStreamObservedApplication?

    init(isURLBlocked: @escaping (URL) async -> Bool,
         isWebBrowser: @escaping (EventStreamApp) -> Bool,
         resolveApplication: @escaping (EventStreamApp) -> EventStreamObservedApplication?) {
        self.isURLBlocked = isURLBlocked
        self.isWebBrowser = isWebBrowser
        self.resolveApplication = resolveApplication
    }

    convenience init(isURLBlocked: @escaping (URL) async -> Bool, resolver: EventStreamApplicationResolver) {
        self.init(isURLBlocked: isURLBlocked, isWebBrowser: resolver.isWebBrowser,
            resolveApplication: resolver.resolve)
    }

    func disposition(for record: EventStreamRecord) async -> EventStreamRecordDisposition {
        guard let app = record.app, isWebBrowser(app),
              let text = record.window?.url, let url = URL(string: text),
              url.host != nil, url.scheme == "http" || url.scheme == "https",
              await isURLBlocked(url), let application = resolveApplication(app) else { return .include }
        let normalized = URL(string: Self.normalizedURLString(url)) ?? url
        return .blocked(.init(application: application, normalizedURL: normalized))
    }

    // Preserve scheme, host, port and path; discard credentials,
    // query and fragment. Policy receives the original URL before normalization.
    nonisolated static func normalizedURLString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }
}
