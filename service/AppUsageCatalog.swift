import AppKit
import CoreServices

final class AppUsageCatalog {
    static let shared = AppUsageCatalog()
    static let recentInterval: TimeInterval = 14 * 24 * 60 * 60

    struct Entry {
        let displayName: String
        let bundleIdentifier: String
        let appPath: String?
        var lastUsedDate: Date?
        var useCount: Int?
        var isRunning = false
        var isFrontmost = false
        var pid: pid_t?

        fileprivate var target: String {
            if let appPath { return URL(fileURLWithPath: appPath).resolvingSymlinksInPath().standardizedFileURL.path }
            return "\(bundleIdentifier)#pid:\(pid ?? 0)"
        }

        var json: JSON {
            var result: JSON = ["displayName": displayName.isEmpty ? bundleIdentifier : displayName,
                                "bundleIdentifier": bundleIdentifier, "isRunning": isRunning, "isFrontmost": isFrontmost]
            if let appPath { result["appPath"] = appPath }
            if let lastUsedDate { result["lastUsedDate"] = lastUsedDate.timeIntervalSinceReferenceDate }
            if let useCount { result["useCount"] = useCount }
            return result
        }
    }

    // URL.path(percentEncoded: false) preserves a
    // directory URL's trailing separator while decoding spaces and percent.
    static func runningAppPath(_ url: URL?) -> String? {
        url?.path(percentEncoded: false)
    }

    private let queue = DispatchQueue(label: "cua.app-usage-index", qos: .utility)
    private let lock = NSLock()
    private let gathering = DispatchGroup()
    private var indexed: [Entry] = []
    private var nextRefresh = ContinuousClock.now
    private var refreshing = false

    static func metadataPath(_ path: String, exists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> String {
        var path = path.hasSuffix("/") ? String(path.dropLast()) : path
        let data = "/System/Volumes/Data"
        if path.hasPrefix(data) { path.removeFirst(data.count) }
        let cryptex = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/"
        if path.hasPrefix(cryptex) {
            let alias = "/Applications/" + path.dropFirst(cryptex.count)
            if exists(alias) { path = alias }
        }
        return path
    }

    private static let metadataAttributes = [kMDItemPath, kMDItemDisplayName, kMDItemCFBundleIdentifier,
        "kMDItemLastUsedDate_Ranking" as CFString, "kMDItemUseCount" as CFString] as CFArray

    static func metadataEntry(_ values: JSON) -> Entry? {
        guard let path = values[kMDItemPath as String] as? String,
              let name = values[kMDItemDisplayName as String] as? String,
              let id = values[kMDItemCFBundleIdentifier as String] as? String else { return nil }
        // Preserve the metadata alias for Bundle and hidden-file checks. Its
        // canonical target is computed separately when entries are merged.
        let url = URL(fileURLWithPath: metadataPath(path))
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == id,
              bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
              (try? url.resourceValues(forKeys: [.isHiddenKey]).isHidden) != true else { return nil }
        return Entry(displayName: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                     bundleIdentifier: id, appPath: url.path,
                     lastUsedDate: values["kMDItemLastUsedDate_Ranking"] as? Date,
                     useCount: values["kMDItemUseCount"] as? Int)
    }

    static func includingRunningFallbacks(_ indexed: [Entry], running: [Entry]) -> [Entry] {
        let known = Set(indexed.map(\.target))
        return indexed + running.compactMap { app in
            guard !known.contains(app.target), let path = app.appPath,
                  let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
                  let values = MDItemCopyAttributes(item, metadataAttributes) as? JSON,
                  let metadata = metadataEntry(values), metadata.target == app.target else { return nil }
            return metadata
        }
    }

    func prewarm() {
        lock.lock()
        if !refreshing, ContinuousClock.now >= nextRefresh {
            refreshing = true
            gathering.enter()
            queue.async { [self] in
                let result = Self.gatherIndexedApps()
                lock.lock()
                if let result { indexed = result }
                refreshing = false
                nextRefresh = .now.advanced(by: .seconds(60))
                lock.unlock()
                gathering.leave()
            }
        }
        lock.unlock()
    }

    func snapshot() -> [Entry] {
        prewarm()
        _ = gathering.wait(timeout: .now() + 1)
        lock.lock(); defer { lock.unlock() }
        return indexed
    }

    static func merge(running: [Entry], indexed: [Entry], now: Date = Date()) -> [Entry] {
        var apps: [String: Entry] = [:]
        for app in running { apps[app.target] = app }
        let threshold = now.addingTimeInterval(-recentInterval)
        for app in indexed {
            if var current = apps[app.target], current.isRunning {
                if let date = app.lastUsedDate { current.lastUsedDate = date }
                if let count = app.useCount { current.useCount = count }
                apps[app.target] = current
            } else if let date = app.lastUsedDate, date >= threshold {
                apps[app.target] = app
            }
        }
        return apps.values.sorted { lhs, rhs in
            if lhs.isFrontmost != rhs.isFrontmost { return lhs.isFrontmost }
            if lhs.isRunning != rhs.isRunning { return lhs.isRunning }
            let leftDate = lhs.lastUsedDate ?? .distantPast, rightDate = rhs.lastUsedDate ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            let leftCount = lhs.useCount ?? 0, rightCount = rhs.useCount ?? 0
            if leftCount != rightCount { return leftCount > rightCount }
            let name = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            return name == .orderedSame ? lhs.target < rhs.target : name == .orderedAscending
        }
    }

    private static func gatherIndexedApps() -> [Entry]? {
        let dateKey = "kMDItemLastUsedDate_Ranking" as CFString
        let countKey = "kMDItemUseCount" as CFString
        let predicate = #"kMDItemContentType == "com.apple.application-bundle" && kMDItemFSName == "*.app" && kMDItemLastUsedDate_Ranking >= $time.today(-14)"#
        let attrs = metadataAttributes
        guard let query = MDQueryCreate(kCFAllocatorDefault, predicate as CFString, nil, [dateKey, countKey] as CFArray) else { return nil }
        MDQuerySetSearchScope(query, [kMDQueryScopeComputer] as CFArray, 0)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return nil }
        defer { MDQueryStop(query) }
        return (0..<MDQueryGetResultCount(query)).compactMap { index in
            guard let raw = MDQueryGetResultAtIndex(query, index) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let values = MDItemCopyAttributes(item, attrs) as? JSON else { return nil }
            return metadataEntry(values)
        }
    }
}
