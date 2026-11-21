import Foundation

enum AppSpecificInstructions {
    static let browser = """
    ## Browser Computer Use

    When navigating to a new website or starting a separate web task, prefer opening a new tab instead of reusing the current tab; reuse the current tab only when the user explicitly asks to continue there or when the current page is clearly the right place to continue the existing workflow.
    """

    private static let resources: [String: URL] = {
        let bundled = Bundle.main.urls(forResourcesWithExtension: nil, subdirectory: "AppInstructions") ?? []
        if !bundled.isEmpty { return index(bundled) }
        guard let directory = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("Resources/AppInstructions", isDirectory: true) else { return [:] }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return index(files)
    }()

    static func resolve(for app: IPCApp) -> String? {
        let bundle = app.appPath.flatMap { Bundle(url: URL(fileURLWithPath: $0, isDirectory: true)) }
        return resolve(bundleIdentifier: app.bundleIdentifier,
                       bundleName: bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
                       urlTypes: bundle?.object(forInfoDictionaryKey: "CFBundleURLTypes"), resources: resources)
    }

    static func index(_ files: [URL]) -> [String: URL] {
        var result: [String: URL] = [:]
        for file in files where file.pathExtension.caseInsensitiveCompare("md") == .orderedSame {
            result[file.deletingPathExtension().lastPathComponent] = file
        }
        return result
    }

    static func resolve(bundleIdentifier: String, bundleName: String?, urlTypes: Any?, resources: [String: URL]) -> String? {
        var candidates: [String] = bundleIdentifier == "com.apple.Music" ? ["AppleMusic"] : []
        if let bundleName { candidates.append(bundleName) }
        candidates.append(bundleIdentifier)
        let appText = candidates.lazy.compactMap { resources[$0] }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .first { !$0.isEmpty }
        if EventStreamBundleShape.supportsHTTP(urlTypes) {
            return appText.map { browser + "\n\n" + $0 } ?? browser
        }
        return appText
    }
}
