import Foundation
import Darwin

// Recording URL policy: the permission cache, the outer policy semantics, and
// the local `[privacy] blocked_domains` list, through the real record filter to
// a JSONL file.

private enum FixtureError: Error { case transport }

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0, reads = 0
    func sample() -> Date { lock.lock(); defer { lock.unlock() }; reads += 1; return Date(timeIntervalSince1970: time) }
    func set(_ time: TimeInterval) { lock.lock(); self.time = time; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
}

private final class ConcurrentResults: @unchecked Sendable {
    private let lock = NSLock(); private var failures = 0
    func failed() { lock.lock(); failures += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return failures }
}

/// Holds permission checks open so concurrent misses can be observed.
@MainActor private final class Gate {
    var calls: [URL] = []
    var pending: [Int: CheckedContinuation<Bool, Error>] = [:]

    func check(_ url: URL) async throws -> Bool {
        let index = calls.count
        calls.append(url)
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func finish(_ index: Int, allowed: Bool) {
        pending.removeValue(forKey: index)?.resume(returning: allowed)
    }
}

@main enum Tests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            if !condition { print("FAIL: \(name)"); fatalError(name) }
            checks += 1; print("PASS: \(name)")
        }
        func settle(_ ready: () -> Bool) async {
            for _ in 0..<1000 { if ready() { return }; await Task.yield() }
            precondition(ready(), "Fixture task did not reach its gate")
        }
        let url = URL(string: "https://alice:owned-secret@example.test:8443/a%20b/%E2%9C%93?private=owned#fragment")!
        let normalized = "https://example.test:8443/a%20b/%E2%9C%93"

        // Permission cache.
        let clock = Clock(), cache = ComputerUseURLBlocklistCache(now: { clock.sample() })
        check("cache miss does not sample clock", cache.isAllowed(forKey: normalized) == nil && clock.count == 0)
        cache.store(isAllowed: true, forKey: normalized)
        check("insertion samples clock once", clock.count == 1)
        check("cache stores permission without inverting it", cache.isAllowed(forKey: normalized) == true)
        clock.set(3599.999)
        check("permission remains valid just before one hour", cache.isAllowed(forKey: normalized) == true)
        clock.set(3600)
        check("exact expiration is a miss", cache.isAllowed(forKey: normalized) == nil)
        let expiredReads = clock.count; clock.set(0)
        check("expired entry is removed even if clock moves backwards", cache.isAllowed(forKey: normalized) == nil && clock.count == expiredReads)
        cache.store(isAllowed: false, forKey: normalized)
        check("false permission is distinct from a missing entry", cache.isAllowed(forKey: normalized) == false)
        clock.set(-10)
        check("entry stays valid when the clock moves back before its store time", cache.isAllowed(forKey: normalized) == false)
        cache.store(isAllowed: true, forKey: normalized)
        clock.set(3590)
        check("replacement has its own insertion-time expiration", cache.isAllowed(forKey: normalized) == nil)
        let shared = ComputerUseURLBlocklistCache(), failures = ConcurrentResults()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let key = "https://cache.fixture/\(index)"
            shared.store(isAllowed: index.isMultiple(of: 2), forKey: key)
            if shared.isAllowed(forKey: key) != index.isMultiple(of: 2) { failures.failed() }
        }
        check("concurrent disjoint cache writes preserve all permissions", failures.count == 0)

        // Outer policy semantics with an injected permission check.
        clock.set(0)
        var permissionCalls: [URL] = [], policyErrors = 0, permission = false, permissionFailure = false
        let policyCache = ComputerUseURLBlocklistCache(now: { clock.sample() })
        let policy = EventStreamRecordingURLPolicy(cache: policyCache, checkPermission: { url in
            permissionCalls.append(url); if permissionFailure { throw FixtureError.transport }; return permission
        }, onError: { _ in policyErrors += 1 })
        check("outer policy inverts denied permission into blocked", await policy.isURLBlocked(url))
        check("checker receives full input URL before cache normalization", permissionCalls == [url])
        let same = URL(string: "https://other:owned@example.test:8443/a%20b/%E2%9C%93?different=yes#other")!
        permission = true
        check("query fragment and credentials share cached permission", await policy.isURLBlocked(same) && permissionCalls.count == 1)
        clock.set(3600)
        check("expiration invokes checker and replaces permission", !(await policy.isURLBlocked(url)) && permissionCalls.count == 2)
        check("cached true permission returns unblocked", !(await policy.isURLBlocked(same)) && permissionCalls.count == 2)
        for changed in ["http://example.test:8443/a%20b/%E2%9C%93", "https://example.test:8444/a%20b/%E2%9C%93", "https://example.test:8443/a%20b/other"] {
            let before = permissionCalls.count; _ = await policy.isURLBlocked(URL(string: changed)!)
            check("scheme port or path distinguishes cache key \(changed)", permissionCalls.count == before + 1)
        }
        for ineligible in ["file:///tmp/owned", "about:blank", "relative", "http:relative"] {
            let before = permissionCalls.count
            check("ineligible URL bypasses checker \(ineligible)", !(await policy.isURLBlocked(URL(string: ineligible)!)) && permissionCalls.count == before)
        }
        permissionFailure = true
        let failingURL = URL(string: "https://failure.fixture/owned")!, beforeFailure = permissionCalls.count
        check("outer default includes on checker error", !(await policy.isURLBlocked(failingURL)))
        check("explicit outer fallback can instead block", await policy.isURLBlocked(failingURL, defaultOnError: true))
        check("errors never populate permission cache", permissionCalls.count == beforeFailure + 2 && policyErrors == 2 && policyCache.isAllowed(forKey: failingURL.absoluteString) == nil)
        permissionFailure = false; permission = false
        check("successful response after error can become cached blocked", await policy.isURLBlocked(failingURL))
        let reused = EventStreamRecordingURLPolicy(cache: policyCache, checkPermission: { _ in fatalError("Shared URL entry must be used") })
        check("cache key does not invent provider or account scope", await reused.isURLBlocked(failingURL))

        var uncachedCalls = 0
        let uncached = EventStreamRecordingURLPolicy(cache: nil, checkPermission: { _ in uncachedCalls += 1; return false })
        _ = await uncached.isURLBlocked(url); _ = await uncached.isURLBlocked(url)
        check("a policy without a cache checks every time", uncachedCalls == 2)

        // Concurrent misses are not coalesced; the last completion wins.
        let gate = Gate(), racingCache = ComputerUseURLBlocklistCache(now: { clock.sample() })
        let racing = EventStreamRecordingURLPolicy(cache: racingCache, checkPermission: { try await gate.check($0) })
        let first = Task { await racing.isURLBlocked(url) }
        await settle { gate.calls.count == 1 }
        let second = Task { await racing.isURLBlocked(same) }
        await settle { gate.calls.count == 2 }
        check("simultaneous misses retain independent checks rather than coalescing", gate.pending.count == 2)
        clock.set(4000); gate.finish(1, allowed: true)
        check("second concurrent check includes", !(await second.value))
        first.cancel(); clock.set(4100); gate.finish(0, allowed: false)
        check("completed permission still applies after cancellation", await first.value)
        check("last completed check replaces same normalized cache key", racingCache.isAllowed(forKey: normalized) == false)
        clock.set(7699.999)
        check("cache TTL is sampled at completion rather than request start", await racing.isURLBlocked(same) && gate.calls.count == 2)
        clock.set(7700)
        check("last completion expires exactly one hour later", racingCache.isAllowed(forKey: normalized) == nil)

        // Local blocklist from $ACUA_HOME/config.toml.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("cua-url-acua-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        setenv(AcuaConfigurationLocation.homeEnvironmentVariable, home.path, 1)
        let configFile = AcuaConfigurationLocation.fileURL()
        func blockDomains(_ domains: [String]) throws {
            let list = domains.map { "\"" + $0 + "\"" }.joined(separator: ", ")
            try "[privacy]\nblocked_domains = [\(list)]\n".write(to: configFile, atomically: true, encoding: .utf8)
        }
        let local = EventStreamRecordingURLPolicy.local()
        check("local policy without a config file blocks nothing", !(await local.isURLBlocked(url)))
        try blockDomains(["example.test"])
        check("local policy applies a newly blocked domain on the next check", await local.isURLBlocked(url))
        check("local policy blocks subdomains", await local.isURLBlocked(URL(string: "https://login.example.test/")!))
        check("local policy does not block a lookalike suffix", !(await local.isURLBlocked(URL(string: "https://notexample.test/")!)))
        try blockDomains([])
        check("local policy applies an unblocked domain on the next check", !(await local.isURLBlocked(url)))

        // Policy -> real record filter -> processor -> disposable JSONL file.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cua-url-recording-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try EventStreamJSONLWriter(sessionID: "owned-session", rootDirectoryURL: directory)
        defer { writer.close() }
        let bundleURL = URL(fileURLWithPath: "/tmp/owned-browser.fixture.app")
        let resolver = EventStreamApplicationResolver(runningApplication: { _ in
            .init(name: "Owned Browser", bundleIdentifier: "owned.browser", bundleURL: bundleURL,
                executableURL: bundleURL.appendingPathComponent("owned-executable"))
        }, applicationURL: { _ in bundleURL }, bundleDetails: { _ in
            .init(displayName: "Owned Browser", name: nil, urlTypes: [["CFBundleURLSchemes": ["http"]]])
        }, executablePath: { _ in nil })
        let application = EventStreamApp(name: "Owned Browser", secureInput: false, processIdentifier: 42, bundleIdentifier: "owned.browser")
        let filter = EventStreamRecordingURLPolicy.local().makeRecordFilter(resolver: resolver)
        let processor = EventStreamRecordProcessor(writer: writer, filter: filter, resolveApplication: resolver.resolve)
        func input(_ id: Int, _ value: String) -> EventStreamRecord {
            .init(id: id, timestamp: Date(timeIntervalSince1970: Double(id)), kind: .keyboardTextInput,
                app: application, window: .init(url: value), keyboard: .init(text: "owned text \(id)", modifiers: []))
        }
        try blockDomains(["example.test"])
        processor.receive(input(1, url.absoluteString))
        await processor.processingTask?.value
        check("blocked domain produces blocked context through complete filter chain", processor.blockedCaptureContext?.normalizedURL.absoluteString == normalized)
        check("blocked typed content never reaches actual JSONL file", try Data(contentsOf: writer.eventsURL).isEmpty)
        check("blocked record does not become observed committed app", processor.observedApplications.isEmpty)
        processor.receive(input(2, "https://allowed.fixture/page"))
        await processor.processingTask?.value
        let allowedLines = try String(contentsOf: writer.eventsURL, encoding: .utf8).split(separator: "\n")
        check("unblocked domain writes exactly the allowed record", allowedLines.count == 1 && allowedLines[0].contains("owned text 2") && !allowedLines[0].contains("owned text 1"))
        check("allowed record clears previous blocked context", processor.blockedCaptureContext == nil && processor.observedApplications.count == 1)
        try "[privacy]\nblocked_domains = [\"https://bad\"]\n".write(to: configFile, atomically: true, encoding: .utf8)
        processor.receive(input(3, "https://example.test/while-invalid"))
        await processor.processingTask?.value
        check("an invalid config file blocks recording instead of dropping the blocklist",
              !(try String(contentsOf: writer.eventsURL, encoding: .utf8).contains("owned text 3")) && processor.blockedCaptureContext != nil)
        check("an invalid config file blocks a site that was never listed", await EventStreamRecordingURLPolicy.local().isURLBlocked(URL(string: "https://allowed.fixture/")!))
        print("Recording URL policy checks: \(checks)")
    }
}
