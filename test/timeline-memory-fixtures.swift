import Foundation
import Darwin

func summaryResources(_ home: URL) -> URL {
    home.appendingPathComponent("memories/extensions/timeline/resources", isDirectory: true)
}

func prepareMemoryFixture(_ item: [String: Any], home: URL) throws {
    let manager = FileManager.default, root = summaryResources(home)
    try manager.createDirectory(at: home, withIntermediateDirectories: true)
    let layout = item["layout"] as? String ?? "directory"
    if layout == "missing" { return }
    try manager.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
    if layout == "file" { try Data("owned root file".utf8).write(to: root); return }
    if layout == "danglingLink" {
        try manager.createSymbolicLink(atPath: root.path, withDestinationPath: home.appendingPathComponent("absent").path)
        return
    }
    if layout == "directoryLink" {
        let target = home.appendingPathComponent("owned-target", isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: root.path, withDestinationPath: target.path)
    } else { try manager.createDirectory(at: root, withIntermediateDirectories: true) }
    func safe(_ path: String) throws -> URL {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
            throw NSError(domain: "OwnedMemoryFixtureGuard", code: 1)
        }
        return root.appendingPathComponent(path)
    }
    for name in item["directories"] as? [String] ?? [] {
        try manager.createDirectory(at: safe(name), withIntermediateDirectories: true)
    }
    for (name, text) in (item["files"] as? [String: String] ?? [:]).sorted(by: { $0.key < $1.key }) {
        let url = try safe(name)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    for (name, target) in item["links"] as? [String: String] ?? [:] {
        let url = try safe(name), destination = try safe(target)
        try manager.createSymbolicLink(atPath: url.path, withDestinationPath: destination.path)
    }
    if item["readOnly"] as? Bool == true {
        guard chmod(root.path, 0o555) == 0 else { throw POSIXError(.EACCES) }
    }
}

func memoryFilesystem(_ home: URL) throws -> [String: Any] {
    let manager = FileManager.default
    var directories = [String](), files = [String: String](), links = [String: String]()
    if let enumerator = manager.enumerator(at: home, includingPropertiesForKeys: nil) {
        for case let url as URL in enumerator {
            guard url.path.hasPrefix(home.path + "/") else { throw NSError(domain: "OwnedMemoryFixtureGuard", code: 2) }
            let name = String(url.path.dropFirst(home.path.count + 1))
            var info = stat()
            guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                links[name] = try manager.destinationOfSymbolicLink(atPath: url.path).replacingOccurrences(of: home.path, with: "$ROOT")
                enumerator.skipDescendants()
            case S_IFDIR: directories.append(name)
            case S_IFREG: files[name] = try Data(contentsOf: url).base64EncodedString()
            default: throw NSError(domain: "OwnedMemoryFixtureGuard", code: 3)
            }
        }
    }
    return ["directories": directories.sorted(), "files": files, "links": links]
}

func memoryError(_ error: Error, home: URL) -> [String: Any] {
    func represent(_ value: Any) -> Any {
        if let error = value as? NSError {
            return ["domain": error.domain, "code": error.code, "userInfo": error.userInfo.mapValues(represent)]
        }
        if let url = value as? URL { return url.absoluteString.replacingOccurrences(of: home.path, with: "$ROOT") }
        if let text = value as? String { return text.replacingOccurrences(of: home.path, with: "$ROOT") }
        if let values = value as? [String: Any] { return values.mapValues(represent) }
        if let values = value as? [Any] { return values.map(represent) }
        if value is NSNumber || value is NSNull { return value }
        return String(reflecting: value).replacingOccurrences(of: home.path, with: "$ROOT")
    }
    let native = error as NSError
    return ["domain": native.domain, "code": native.code,
            "description": native.localizedDescription.replacingOccurrences(of: home.path, with: "$ROOT"),
            "userInfo": native.userInfo.mapValues(represent)]
}

func summaryInterval(_ operation: [String: Any]) -> DateInterval {
    DateInterval(start: Date(timeIntervalSince1970: operation["start"] as! Double),
                 duration: operation["duration"] as! Double)
}
