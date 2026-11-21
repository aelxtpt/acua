import AppKit
import Darwin

struct EventStreamObservedApplication: Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let bundleURL: URL?
    let executableURL: URL?
}

// Resolves the observed application and the browser of a recorded event.
// No fallback to the current frontmost app: that would attribute a finished
// process's event to an unrelated application.
@MainActor
final class EventStreamApplicationResolver {
    struct RunningApplication {
        var name: String?
        var bundleIdentifier: String?
        var bundleURL: URL?
        var executableURL: URL?
    }
    struct BundleDetails {
        var displayName: String?
        var name: String?
        var urlTypes: Any?

        // Whether the bundle declares the http URL scheme. Both casts are
        // strict, and only the exact scheme "http" qualifies (not https alone).
        var supportsHTTP: Bool {
            guard let types = urlTypes as? [[String: Any]] else { return false }
            return types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("http") == true }
        }

        static func read(_ url: URL) -> Self? {
            guard let bundle = Bundle(url: url) else { return nil }
            return Self(displayName: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                name: bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
                urlTypes: bundle.object(forInfoDictionaryKey: "CFBundleURLTypes"))
        }
    }
    private let runningApplication: (Int32) -> RunningApplication?
    private let applicationURL: (String) -> URL?
    private let bundleDetails: (URL) -> BundleDetails?
    private let executablePath: (Int32) -> String?

    init(runningApplication: @escaping (Int32) -> RunningApplication?,
         applicationURL: @escaping (String) -> URL?,
         bundleDetails: @escaping (URL) -> BundleDetails?,
         executablePath: @escaping (Int32) -> String?) {
        self.runningApplication = runningApplication
        self.applicationURL = applicationURL
        self.bundleDetails = bundleDetails
        self.executablePath = executablePath
    }

    convenience init() {
        self.init(runningApplication: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return RunningApplication(name: app.localizedName, bundleIdentifier: app.bundleIdentifier,
                bundleURL: app.bundleURL, executableURL: app.executableURL)
        }, applicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
        bundleDetails: BundleDetails.read, executablePath: NativeProcessPath.read)
    }

    private func lookup(_ app: EventStreamApp) -> (RunningApplication?, String?, URL?) {
        let running = app.processIdentifier.flatMap(runningApplication)
        let bundleIdentifier = app.bundleIdentifier ?? running?.bundleIdentifier
        let url = running?.bundleURL ?? bundleIdentifier.flatMap(applicationURL)
        return (running, bundleIdentifier, url)
    }

    func isWebBrowser(_ app: EventStreamApp) -> Bool {
        let (_, _, url) = lookup(app)
        return url.flatMap(bundleDetails)?.supportsHTTP ?? false
    }

    func resolve(_ app: EventStreamApp) -> EventStreamObservedApplication? {
        let (running, bundleIdentifier, bundleURL) = lookup(app)
        let details = bundleURL.flatMap(bundleDetails)
        guard let name = [app.name, running?.name, details?.displayName, details?.name]
            .compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        let id: String
        if let bundleIdentifier { id = "bundle:" + bundleIdentifier }
        else if let bundleURL { id = "url:" + bundleURL.standardizedFileURL.path }
        else { id = "name:" + name }
        let executable = running?.executableURL ?? app.processIdentifier.flatMap(executablePath).map { URL(fileURLWithPath: $0) }
        return EventStreamObservedApplication(id: id, name: name, bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL, executableURL: executable)
    }

    // Recorder app metadata. Secure input belongs to a specific
    // process; another process holding secure input does not mark this app.
    func snapshot(processIdentifier pid: Int32, fallbackName: String?, secureInputPID: () -> Int?) -> EventStreamApp? {
        let liveName = runningApplication(pid)?.name
        guard let name = [liveName, fallbackName].compactMap({ $0 }).first(where: { !$0.isEmpty }) else { return nil }
        let secureInput = secureInputPID() == Int(pid)
        let identifier = runningApplication(pid)?.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
        return EventStreamApp(name: name, secureInput: secureInput, processIdentifier: pid, bundleIdentifier: identifier)
    }

    func snapshot(processIdentifier pid: Int32, fallbackName: String?) -> EventStreamApp? {
        snapshot(processIdentifier: pid, fallbackName: fallbackName) {
            let session = CGSessionCopyCurrentDictionary() as? [String: Any]
            return session?["kCGSSessionSecureInputPID"] as? Int
        }
    }

    private enum NativeProcessPath {
        private typealias ReadPath = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32) -> Int32
        private static let image = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY | RTLD_LOCAL)
        private static let function: ReadPath? = image.flatMap { dlsym($0, "proc_pidpath") }.map { unsafeBitCast($0, to: ReadPath.self) }
        static func read(_ pid: Int32) -> String? {
            guard let function else { return nil }
            var bytes = [UInt8](repeating: 0, count: 4096)
            guard function(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
            return String(bytes: bytes.prefix { $0 != 0 }, encoding: .utf8)
        }
    }
}
