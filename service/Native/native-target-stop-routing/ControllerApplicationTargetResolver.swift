import Foundation

enum ControllerApplicationTargetLookupError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalid(String)
    case ambiguous(String, [String])
    var description: String {
        switch self {
        case .invalid(let query): "Invalid app: \(query)"
        case .ambiguous(let query, let paths):
            "Ambiguous app identifier '\(query)'. Multiple apps share this bundle identifier: " + paths.joined(separator: ", ") + ". Use an app name or full app path instead."
        }
    }
}

/// Resolves an app identifier, name or path to a canonical application target.
@MainActor struct ControllerApplicationTargetResolver {
    struct Environment {
        let bundleIdentifierAtPath: (String) -> String?
        let bundleIdentifierAtURL: (URL) -> String?
        let canonicalURL: (URL) -> URL
        let installedURLs: (String) -> [URL]
        let runningURLs: (String) -> [URL]
        let pathForName: (String) -> String?
    }
    let environment: Environment
    private func pathTarget(_ path: String) -> ComputerUseApplicationTarget? {
        guard let bundle = environment.bundleIdentifierAtPath(path) else { return nil }
        return .init(bundleIdentifier: bundle, url: environment.canonicalURL(URL(fileURLWithPath:path)))
    }
    private func targets(_ urls: [URL], bundle: String) -> [ComputerUseApplicationTarget] {
        var seen = Set<String>()
        return urls.compactMap { url in
            // Form the target before validating metadata, and deduplicate only
            // after exact case-sensitive bundle equality.
            let target = ComputerUseApplicationTarget(bundleIdentifier:bundle,url:environment.canonicalURL(url))
            guard environment.bundleIdentifierAtURL(target.url) == bundle,
                  seen.insert(target.identifier).inserted else { return nil }
            return target
        }
    }
    func applicationTargets(bundleIdentifier: String) -> [ComputerUseApplicationTarget] {
        //Installed URLs are acquired first. Running metadata is filtered and
        //deduplicated, then validated again ahead of the installed URL list.
        let installed = environment.installedURLs(bundleIdentifier)
        let running = targets(environment.runningURLs(bundleIdentifier),bundle:bundleIdentifier)
        return targets(running.map(\.url)+installed,bundle:bundleIdentifier)
    }
    func resolve(_ query: String) throws -> ComputerUseApplicationTarget {
        if let target = pathTarget(query) { return target }
        let found = applicationTargets(bundleIdentifier:query)
        if found.count == 1 { return found[0] }
        if found.count > 1 {
            throw ControllerApplicationTargetLookupError.ambiguous(query,found.map(\.identifier).sorted())
        }
        if let path = environment.pathForName(query),let target = pathTarget(path) { return target }
        throw ControllerApplicationTargetLookupError.invalid(query)
    }
}
