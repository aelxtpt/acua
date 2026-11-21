import AppKit
import Foundation

@main
struct EventStreamPolicyTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ name: String, _ value: @autoclosure () -> Bool) {
        guard value() else { fatalError("FAIL: \(name)") }
        checks += 1; print("PASS: \(name)")
    }
    @MainActor static func main() async throws {
        typealias Resolver = EventStreamApplicationResolver
        let bundleURL = URL(fileURLWithPath: "/tmp/apps/../Browser.app", isDirectory: true)
        let executableURL = URL(fileURLWithPath: "/tmp/Browser.app/Contents/MacOS/Browser")
        var running: Resolver.RunningApplication? = .init(name: "Live name", bundleIdentifier: "live.id", bundleURL: bundleURL, executableURL: executableURL)
        var foundURL: URL? = URL(fileURLWithPath: "/tmp/Located.app", isDirectory: true)
        var details: Resolver.BundleDetails? = .init(displayName: "Display name", name: "Bundle name", urlTypes: [["CFBundleURLSchemes":["https","http"]]])
        var lookedUpBundles: [String] = [], pathLookups: [Int32] = []
        let resolver = Resolver(runningApplication: { _ in running }, applicationURL: { lookedUpBundles.append($0); return foundURL },
            bundleDetails: { _ in details }, executablePath: { pathLookups.append($0); return "/tmp/fallback-executable" })
        let app = EventStreamApp(name: "Event name", secureInput: false, processIdentifier: 42, bundleIdentifier: "event.id")
        let observed = resolver.resolve(app)!
        check("event name and event bundle ID win over process metadata", observed.name == "Event name" && observed.bundleIdentifier == "event.id" && observed.id == "bundle:event.id")
        check("live bundle URL wins without LaunchServices lookup", observed.bundleURL == bundleURL && lookedUpBundles.isEmpty)
        check("live executable URL wins over process-path fallback", observed.executableURL == executableURL && pathLookups.isEmpty)
        check("browser is detected through declared HTTP scheme", resolver.isWebBrowser(app))
        check("empty event name falls back to nonempty running name", resolver.resolve(.init(name: "", secureInput: false, processIdentifier: 42))?.name == "Live name")
        check("whitespace event name is preserved rather than trimmed", resolver.resolve(.init(name: "  ", secureInput: false, processIdentifier: 42))?.name == "  ")
        running?.name = ""
        check("bundle display name is third name candidate", resolver.resolve(.init(secureInput: false, processIdentifier: 42))?.name == "Display name")
        details?.displayName = ""
        check("bundle name is fourth name candidate", resolver.resolve(.init(secureInput: false, processIdentifier: 42))?.name == "Bundle name")
        details?.name = nil
        check("missing all name candidates yields no observed app", resolver.resolve(.init(secureInput: false, processIdentifier: 42)) == nil)
        running = .init(name: "Live", bundleIdentifier: nil, bundleURL: bundleURL)
        let pathIdentity = resolver.resolve(.init(secureInput: false, processIdentifier: 42))!
        check("bundle URL identity standardizes dot segments", pathIdentity.id == "url:/tmp/Browser.app")
        check("stored bundle URL retains original URL value", pathIdentity.bundleURL == bundleURL)
        check("missing native executable uses PID path fallback", pathIdentity.executableURL == URL(fileURLWithPath: "/tmp/fallback-executable") && pathLookups == [42])
        running = nil; foundURL = nil
        let named = resolver.resolve(.init(name: "Stopped", secureInput: false))!
        check("finished process can retain event name identity", named.id == "name:Stopped" && named.bundleURL == nil && named.executableURL == nil)
        check("no PID does not trigger process-path lookup", pathLookups == [42])
        check("supplied empty bundle ID remains present", resolver.resolve(.init(name: "Name", secureInput: false, bundleIdentifier: ""))?.id == "bundle:")
        foundURL = URL(fileURLWithPath: "/tmp/Located.app")
        details = .init(displayName: "Located display", name: "Located bundle", urlTypes: [["CFBundleURLSchemes":["http"]]])
        check("finished process resolves bundle using event bundle identifier", resolver.resolve(.init(secureInput: false, bundleIdentifier: "stopped.id"))?.name == "Located display" && lookedUpBundles.last == "stopped.id")
        check("HTTPS-only declaration is not browser detection", !Resolver.BundleDetails(urlTypes: [["CFBundleURLSchemes":["https"]]]).supportsHTTP)
        check("scheme declaration is case sensitive", !Resolver.BundleDetails(urlTypes: [["CFBundleURLSchemes":["HTTP"]]]).supportsHTTP)
        check("malformed URL types or mixed scheme arrays are rejected", !Resolver.BundleDetails(urlTypes: ["wrong",["CFBundleURLSchemes":["http"]]]).supportsHTTP && !Resolver.BundleDetails(urlTypes: [["CFBundleURLSchemes":["http",1]]]).supportsHTTP)
        check("later valid URL type can supply HTTP support", Resolver.BundleDetails(urlTypes: [["CFBundleURLSchemes":1],["CFBundleURLSchemes":["http"]]]).supportsHTTP)

        running = .init(name: "Live snapshot", bundleIdentifier: "live.id")
        check("record app snapshot prefers live name and attributes secure input by PID", resolver.snapshot(processIdentifier: 42, fallbackName: "Owner", secureInputPID: {42}) == .init(name: "Live snapshot", secureInput: true, processIdentifier: 42, bundleIdentifier: "live.id"))
        check("other process holding secure input does not mark this app", resolver.snapshot(processIdentifier: 42, fallbackName: nil, secureInputPID: {43})?.secureInput == false)
        running = .init(name: "", bundleIdentifier: "")
        check("owner-name fallback keeps PID and omits empty bundle identifier", resolver.snapshot(processIdentifier: 42, fallbackName: "Window owner", secureInputPID: {nil}) == .init(name: "Window owner", secureInput: false, processIdentifier: 42))
        var queriedSecure = false
        let missingSnapshot = resolver.snapshot(processIdentifier: 42, fallbackName: "", secureInputPID: { queriedSecure = true; return 42 })
        check("nameless app is absent without querying secure input", missingSnapshot == nil && !queriedSecure)

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("cua-event-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let nativeBundle = temp.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(at: nativeBundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier":"local.event.policy", "CFBundleName":"Fixture name", "CFBundleDisplayName":"Fixture display", "CFBundlePackageType":"APPL", "CFBundleURLTypes":[["CFBundleURLSchemes":["http"]]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: nativeBundle.appendingPathComponent("Contents/Info.plist"))
        let bundle = Resolver.BundleDetails.read(nativeBundle)
        check("native NSBundle reads real local fixture names and schemes", bundle?.displayName == "Fixture display" && bundle?.name == "Fixture name" && bundle?.supportsHTTP == true)
        let nativeSelf = Resolver().resolve(.init(name: "Native self", secureInput: false, processIdentifier: getpid()))
        check("native application/process lookup resolves executable without UI actions", nativeSelf?.name == "Native self" && nativeSelf?.executableURL.map { FileManager.default.fileExists(atPath: $0.path) } == true)

        var calls: [String] = [], isBrowser = true, shouldBlock = true, canResolve = true
        let filter = EventStreamURLPolicyRecordFilter(isURLBlocked: { url in
            calls.append("policy:" + url.absoluteString); await Task.yield(); return shouldBlock
        }, isWebBrowser: { _ in calls.append("browser"); return isBrowser }, resolveApplication: { _ in
            calls.append("resolve"); return canResolve ? observed : nil
        })
        let inputURL = "https://alice:synthetic-password@example.test:8443/a%20b/c?query=synthetic#anchor"
        let record = EventStreamRecord(id: 1, timestamp: Date(timeIntervalSince1970: 0), kind: .keyboardTextInput,
            app: app, window: .init(title: "Private", url: inputURL))
        let result = await filter.disposition(for: record)
        let expectedURL = URL(string: "https://example.test:8443/a%20b/c")!
        check("blocked record yields observed app and normalized URL", result == .blocked(.init(application: observed, normalizedURL: expectedURL)))
        check("policy receives full original URL before normalization and app resolution", calls == ["browser","policy:" + inputURL,"resolve"])
        if case let .blocked(context) = result { check("blocked ID is normalized URL alone", context.id == expectedURL.absoluteString) }
        else { fatalError("expected blocked context") }
        shouldBlock = false; calls = []
        let allowed = await filter.disposition(for: record)
        check("allowed URL includes record without resolving app", allowed == .include && calls == ["browser","policy:" + inputURL])
        isBrowser = false; calls = []
        let nonbrowser = await filter.disposition(for: record)
        check("non-browser skips URL policy", nonbrowser == .include && calls == ["browser"])
        isBrowser = true; shouldBlock = true; canResolve = false; calls = []
        let unresolved = await filter.disposition(for: record)
        check("nameless-app result remains include after blocked lookup", unresolved == .include && calls.last == "resolve")
        canResolve = true
        for url in ["file:///tmp/file", "about:blank", "https:relative", "http:", "https://[invalid"] {
            calls = []
            var changed = record; changed.window?.url = url
            let disposition = await filter.disposition(for: changed)
            check("non-web or unparseable URL skips policy: \(url)", disposition == .include && calls == ["browser"])
        }
        calls = []; var absent = record; absent.app = nil
        let missingApp = await filter.disposition(for: absent)
        check("boundary without app skips every policy dependency", missingApp == .include && calls.isEmpty)
        calls = []; absent = record; absent.window = nil
        let missingWindow = await filter.disposition(for: absent)
        check("missing window skips URL policy after browser classification", missingWindow == .include && calls == ["browser"])
        calls = []; absent = record; absent.window?.url = nil
        let missingURL = await filter.disposition(for: absent)
        check("missing URL skips policy", missingURL == .include && calls == ["browser"])
        let normalizedCases = [
            ("http://user:pass@example.test/path?q=x#y", "http://example.test/path"),
            ("https://example.test:9443/a/../b?x=1#z", "https://example.test:9443/a/../b"),
            ("https://[::1]:8443/a%2Fb?x=y", "https://[::1]:8443/a%2Fb"),
            ("https://example.test/ação?q=1", "https://example.test/a%C3%A7%C3%A3o")]
        check("normalization removes only credentials/query/fragment", normalizedCases.allSatisfy { EventStreamURLPolicyRecordFilter.normalizedURLString(URL(string: $0.0)!) == $0.1 })
        let direct = EventStreamURLPolicyRecordFilter(isURLBlocked: { _ in true }, resolver: resolver)
        let resolvedPolicy = await direct.disposition(for: record)
        check("resolver-backed policy uses real metadata pipeline", { if case .blocked = resolvedPolicy { return true }; return false }())
        var continuation: CheckedContinuation<Bool,Never>?
        var mutable = record
        let suspended = EventStreamURLPolicyRecordFilter(isURLBlocked: { _ in await withCheckedContinuation { continuation=$0 } },
            isWebBrowser: { _ in true }, resolveApplication: { app in
                .init(id:"bundle:"+(app.bundleIdentifier ?? ""),name:app.name ?? "",bundleIdentifier:app.bundleIdentifier,bundleURL:nil,executableURL:nil)
            })
        let task = Task { await suspended.disposition(for: mutable) }
        while continuation == nil { await Task.yield() }
        mutable.app?.bundleIdentifier="later.app"
        mutable.window?.url="https://later.test/"
        continuation!.resume(returning:true)
        let stable = await task.value
        check("record identity and URL survive asynchronous policy suspension", { if case let .blocked(context)=stable {return context.application.bundleIdentifier=="event.id" && context.normalizedURL==expectedURL};return false }())
        print("EVENT STREAM APPLICATION AND URL POLICY: \(checks) checks passed")
    }
}
