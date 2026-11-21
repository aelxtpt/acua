import Foundation

@main enum AppUsageCatalogTests {
    static func main() throws {
        let now = Date(timeIntervalSinceReferenceDate: 1_500_000)
        let threshold = now.addingTimeInterval(-AppUsageCatalog.recentInterval)
        func check(_ name: String, _ value: Bool) { precondition(value, name); print("PASS \(name)") }
        check("missing running bundle URL omits appPath", AppUsageCatalog.runningAppPath(nil) == nil)
        check("running directory path keeps its trailing separator",
              AppUsageCatalog.runningAppPath(URL(string: "file:///Applications/Owned.app/")) == "/Applications/Owned.app/")
        check("running app paths decode spaces percent Unicode and hash",
              AppUsageCatalog.runningAppPath(URL(string: "file:///Applications/Pol%C3%ADtica%20%25%23.app/")) == "/Applications/Política %#.app/")
        check("a non-directory bundle URL is not given an invented separator",
              AppUsageCatalog.runningAppPath(URL(string: "file:///Applications/Owned.app")) == "/Applications/Owned.app")
        func app(_ name: String, _ id: String, _ path: String? = nil, used: Date? = nil, count: Int? = nil,
                 running: Bool = false, frontmost: Bool = false, pid: Int32? = nil) -> AppUsageCatalog.Entry {
            .init(displayName: name, bundleIdentifier: id, appPath: path, lastUsedDate: used,
                  useCount: count, isRunning: running, isFrontmost: frontmost, pid: pid)
        }
        let running = [
            app("Foreground", "test.foreground", "/fixture/foreground.app", running: true, frontmost: true),
            app("Editor", "test.editor", "/fixture/editor.app", running: true),
            app("Another", "test.another", running: true, pid: 10),
            app("Another", "test.another", running: true, pid: 11),
        ]
        let indexed = [
            app("Indexed Editor", "test.editor", "/fixture/sub/../editor.app", used: now, count: 5),
            app("Alternate Editor", "test.editor", "/other/editor.app", used: now),
            app("Zebra", "test.zebra", "/fixture/zebra.app", used: threshold, count: 10),
            app("Alpha", "test.alpha", "/fixture/alpha.app", used: threshold, count: 1),
            app("beta", "test.beta", "/fixture/beta.app", used: threshold, count: 1),
            app("Old", "test.old", "/fixture/old.app", used: threshold.addingTimeInterval(-1)),
            app("Unknown", "test.unknown", "/fixture/unknown.app"),
        ]
        let merged = AppUsageCatalog.merge(running: running, indexed: indexed, now: now)
        check("foreground leads, then running apps, then recent apps", merged.map(\.displayName) ==
              ["Foreground", "Editor", "Another", "Another", "Alternate Editor", "Zebra", "Alpha", "beta"])
        check("running app keeps live flags and receives matching indexed usage",
              merged[1].isRunning && !merged[1].isFrontmost && merged[1].lastUsedDate == now && merged[1].useCount == 5)
        check("different bundle paths and pathless process IDs remain distinct",
              merged.filter { $0.bundleIdentifier == "test.editor" }.count == 2 &&
              merged.filter { $0.bundleIdentifier == "test.another" }.compactMap(\.pid) == [10, 11])
        check("indexed apps require a date within the inclusive fourteen-day window",
              merged.contains { $0.bundleIdentifier == "test.zebra" } &&
              !merged.contains { ["test.old", "test.unknown"].contains($0.bundleIdentifier) })
        check("wire dates use the Foundation reference epoch", merged[1].json["lastUsedDate"] as? Double == 1_500_000)
        check("wire always includes both booleans and omits missing usage",
              merged[0].json["isFrontmost"] as? Bool == true && merged[0].json["isRunning"] as? Bool == true &&
              merged[0].json["lastUsedDate"] == nil && merged[0].json["useCount"] == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-catalog-\(UUID())")
        let installed = directory.appendingPathComponent("Owned.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let alias = directory.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: installed)
        let canonical = AppUsageCatalog.merge(running: [app("Owned", "test.alias", installed.path, running: true)],
            indexed: [app("Alias", "test.alias", alias.path, used: now, count: 8)], now: now)
        check("filesystem aliases merge into the same running application", canonical.count == 1 && canonical[0].isRunning)
        check("alias metadata enriches the live entry", canonical[0].lastUsedDate == now && canonical[0].useCount == 8)
        let retained = AppUsageCatalog.merge(running: [app("Owned", "test.alias", installed.path,
            used: threshold.addingTimeInterval(-100), count: 3, running: true)], indexed: [], now: now)
        check("running applications retain usage older than the recent-app window", retained.count == 1 && retained[0].useCount == 3)
        check("metadata paths remove the data-volume prefix and trailing separator",
              AppUsageCatalog.metadataPath("/System/Volumes/Data/Applications/Owned.app/") == "/Applications/Owned.app")
        let cryptex = "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Owned.app"
        check("Cryptex metadata uses an existing Applications alias",
              AppUsageCatalog.metadataPath(cryptex, exists: { $0 == "/Applications/Owned.app" }) == "/Applications/Owned.app")
        check("Cryptex metadata keeps the original path when its alias is absent",
              AppUsageCatalog.metadataPath(cryptex, exists: { _ in false }) == cryptex)
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "test.alias", "CFBundleName": "Owned", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: installed.appendingPathComponent("Contents/Info.plist"))
        func metadata(_ path: String, id: String = "test.alias") -> JSON {
            ["kMDItemPath": path, "kMDItemDisplayName": "Owned.app", "kMDItemCFBundleIdentifier": id,
             "kMDItemLastUsedDate_Ranking": threshold.addingTimeInterval(-100), "kMDItemUseCount": 3]
        }
        let accepted = AppUsageCatalog.metadataEntry(metadata(installed.path))
        check("validated metadata retains old usage for a running-app fallback",
              accepted?.useCount == 3 && accepted?.displayName == "Owned")
        check("metadata with a different bundle identity is rejected",
              AppUsageCatalog.metadataEntry(metadata(installed.path, id: "test.other")) == nil)
        let hidden = directory.appendingPathComponent(".Hidden.app")
        try FileManager.default.createSymbolicLink(at: hidden, withDestinationURL: installed)
        check("hidden metadata aliases are checked before resolving their target",
              AppUsageCatalog.metadataEntry(metadata(hidden.path)) == nil)
    }
}
