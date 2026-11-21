import AppKit
import ApplicationServices

@main @MainActor
private enum NativePIPFocusTests {
    private final class WindowEvent: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded = false
        var received: Bool { lock.withLock { recorded } }
        func record() { lock.withLock { recorded = true } }
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func main() {
        let app = NSApplication.shared
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--fixture",
           let parent = Int32(CommandLine.arguments[3]) {
            let directory = URL(fileURLWithPath: CommandLine.arguments[2])
            DispatchQueue.main.async { runFixture(directory, parent: parent) }
        } else {
            app.setActivationPolicy(.accessory)
            Task {
                do {
                    try await test()
                    exit(0)
                } catch {
                    fputs("FAIL \(error)\n", stderr)
                    exit(1)
                }
            }
        }
        app.run()
    }

    private final class FixtureWindows {
        var primary: NSWindow?
        var alternate: NSWindow?
        init(primary: NSWindow, alternate: NSWindow) { self.primary = primary; self.alternate = alternate }
    }

    private static func runFixture(_ directory: URL, parent: Int32) {
        NSApplication.shared.setActivationPolicy(.regular)
        let primary = NSWindow(contentRect: CGRect(x: 100, y: 150, width: 320, height: 200),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let alternate = NSWindow(contentRect: CGRect(x: 180, y: 210, width: 320, height: 200),
                                 styleMask: [.titled, .closable], backing: .buffered, defer: false)
        primary.isReleasedWhenClosed = false
        alternate.isReleasedWhenClosed = false
        primary.title = "CUA PiP focus fixture"
        alternate.title = "CUA PiP focus alternate"
        primary.orderFrontRegardless()
        alternate.orderFrontRegardless()
        alternate.makeKey()
        let ids = [primary.windowNumber, alternate.windowNumber]
        try! JSONEncoder().encode(ids).write(to: directory.appendingPathComponent("ready"), options: .atomic)
        let closePrimary = directory.appendingPathComponent("close-primary")
        let closeAlternate = directory.appendingPathComponent("close-alternate")
        let resizePrimary = directory.appendingPathComponent("resize-primary")
        let windows = FixtureWindows(primary: primary, alternate: alternate)
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            if getppid() != parent { exit(0) }
            if FileManager.default.fileExists(atPath: closePrimary.path) {
                try? FileManager.default.removeItem(at: closePrimary)
                windows.primary?.close()
                windows.primary = nil
            }
            if FileManager.default.fileExists(atPath: closeAlternate.path) {
                try? FileManager.default.removeItem(at: closeAlternate)
                windows.alternate?.close()
                windows.alternate = nil
            }
            if FileManager.default.fileExists(atPath: resizePrimary.path) {
                try? FileManager.default.removeItem(at: resizePrimary)
                windows.primary?.setContentSize(CGSize(width: 356, height: 214))
            }
        }
    }

    private struct Fixture {
        let process: Process
        let directory: URL
        let app: NSRunningApplication
        let primary: CGWindowID
        let alternate: CGWindowID
    }

    private static func test() async throws {
        guard AXIsProcessTrusted() else { throw Failure("Accessibility permission is required") }
        guard CGPreflightScreenCaptureAccess() else { throw Failure("Screen Recording permission is required") }
        let initial = NSWorkspace.shared.frontmostApplication
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cua-pip-focus-\(UUID())")
        var processes: [Process] = []
        defer {
            if let front = NSWorkspace.shared.frontmostApplication,
               processes.contains(where: { $0.processIdentifier == front.processIdentifier }) {
                _ = initial?.activate(options: [])
            }
            for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: root)
        }
        func launch(_ label: String) async throws -> Fixture {
            let directory = root.appendingPathComponent(label)
            let app = directory.appendingPathComponent("Fixture.app")
            let contents = app.appendingPathComponent("Contents")
            let macos = contents.appendingPathComponent("MacOS")
            try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
            let executable = macos.appendingPathComponent("Fixture")
            try FileManager.default.copyItem(at: Bundle.main.executableURL!, to: executable)
            let plist = ["CFBundleIdentifier": "test.acua.pip-focus.\(label)",
                         "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL", "CFBundleName": "CUA PiP Fixture"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--fixture", directory.path, String(getpid())]
            try process.run()
            processes.append(process)
            let ready = directory.appendingPathComponent("ready")
            try await waitFor("starts disposable \(label) app") {
                FileManager.default.fileExists(atPath: ready.path) && NSRunningApplication(processIdentifier: process.processIdentifier) != nil
            }
            let ids = try JSONDecoder().decode([CGWindowID].self, from: Data(contentsOf: ready))
            guard ids.count == 2, let running = NSRunningApplication(processIdentifier: process.processIdentifier) else {
                throw Failure("Missing fixture identity")
            }
            try await waitFor("WindowServer sees both \(label) windows") { ids.allSatisfy(windowExists) }
            return Fixture(process: process, directory: directory, app: running, primary: ids[0], alternate: ids[1])
        }

        let previous = try await launch("previous")
        let target = try await launch("target")
        _ = previous.app.activate(options: [])
        try await waitFor("previous app starts as the foreground fixture") {
            isFocused(previous, window: previous.alternate)
        }
        try check(RemoteHostedPIPWindowFocus(windowID: target.primary, expectedPID: previous.process.processIdentifier) == nil,
                  "mismatched owner PID is rejected")
        let publisher = RemoteHostedPIPContentPublisher()
        let connection = NSXPCConnection(listenerEndpoint: publisher.endpointForHostConnection())
        connection.exportedInterface = RemoteHostedPIPXPC.hostInterface()
        connection.exportedObject = FocusHost()
        connection.remoteObjectInterface = RemoteHostedPIPXPC.producerInterface()
        connection.activate()
        defer { connection.invalidate() }
        guard let producer = connection.remoteObjectProxy as? RemoteHostedPIPContentProducerXPCProtocol else {
            throw Failure("Could not connect the disposable PiP host")
        }
        try await request { producer.connect(reply: $0) }
        let stream = publisher.publishWindowStream(threadID: "focus-thread", turnID: "focus-turn", windowID: target.primary)
        try await waitFor("the disposable XPC host receives a real window presentation") { stream.isPublished }
        func focus() async throws {
            try await request { producer.performAction(presentationID: stream.presentationID, kind: "focus-presentation", reply: $0) }
        }

        try await focus()
        do {
            try await waitFor("first focus activates the app and raises the exact PiP window", stable: .milliseconds(150)) {
                isPresented(target, window: target.primary)
            }
        } catch {
            throw Failure("focus target pid \(target.process.processIdentifier), window \(target.primary), foreground pid \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), front fixture window \(frontWindow(target) ?? 0), focused window \(focusedWindow(pid: target.process.processIdentifier) ?? 0)")
        }
        try await focus()
        do {
            try await waitFor("second focus restores the previous app and its exact window") { isPresented(previous, window: previous.alternate) }
        } catch {
            throw Failure("restore expected pid \(previous.process.processIdentifier), window \(previous.alternate), foreground pid \(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), front fixture window \(frontWindow(previous) ?? 0), focused window \(focusedWindow(pid: previous.process.processIdentifier) ?? 0)")
        }
        try await focus()
        try await waitFor("focusing again remembers a fresh return destination", stable: .milliseconds(150)) {
            isPresented(target, window: target.primary)
        }

        try Data().write(to: previous.directory.appendingPathComponent("close-alternate"))
        try await waitFor("previous window closes before restoration") { !windowExists(previous.alternate) }
        try await focus()
        try await waitFor("closed previous window falls back to its running application") {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.process.processIdentifier
        }
        let event = WindowEvent()
        if let observer = RemoteHostedPIPWindowServerObserver(windowIDs: [target.primary], onEvent: { _, _ in event.record() }) {
            try Data().write(to: target.directory.appendingPathComponent("resize-primary"))
            try await waitFor("WindowServer delivers a resize from the captured app process") { event.received }
            withExtendedLifetime(observer) {}
        }
        try Data().write(to: target.directory.appendingPathComponent("close-primary"))
        try await waitFor("target window closes while the PiP handle exists") { !windowExists(target.primary) }
        stream.willEndStream()
        try await focus()
        try await Task.sleep(for: .milliseconds(100))
        try check(NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.process.processIdentifier,
                  "closed target cannot activate its remaining window")
    }

    private static func request(_ send: (@escaping RemoteHostedPIPReply) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            send { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private static func isFocused(_ fixture: Fixture, window: CGWindowID) -> Bool {
        let pid = fixture.process.processIdentifier
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid && focusedWindow(pid: pid) == window
    }

    private static func isPresented(_ fixture: Fixture, window: CGWindowID) -> Bool {
        let pid = fixture.process.processIdentifier
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid &&
            (focusedWindow(pid: pid) == window || frontWindow(fixture) == window)
    }

    private static func frontWindow(_ fixture: Fixture) -> CGWindowID? {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return windows.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
            .first { $0 == fixture.primary || $0 == fixture.alternate }
    }

    private static func focusedWindow(pid: Int32) -> CGWindowID? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return try? AccessibilityWindowSPI.windowID(unsafeBitCast(value, to: AXUIElement.self))
    }

    private static func windowExists(_ id: CGWindowID) -> Bool {
        let windows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []
        return windows.contains { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == id }
    }

    private static func waitFor(_ title: String, stable: Duration = .zero, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        var matchedSince: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            if condition() {
                let now = ContinuousClock.now
                let since = matchedSince ?? now
                matchedSince = since
                if now - since >= stable { try check(true, title); return }
            } else {
                matchedSince = nil
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure(title)
    }

    private static func check(_ passed: Bool, _ title: String) throws {
        guard passed else { throw Failure(title) }
        print("PASS \(title)")
    }
}

private final class FocusHost: NSObject, RemoteHostedPIPContentHostXPCProtocol {
    func publishPresentation(id: String, threadID: String, turnID: String, contextID: UInt32, width: Double, height: Double, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func setSourceProcessIdentifier(_ pid: Int32, presentationID: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func publishFrame(presentationID: String, videoData: Data, decoderConfiguration: Data?, codec: String, timestamp: UInt64, isKeyFrame: Bool, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func prepareOperation(presentationID: String, operationID: UInt64, kind: String, contextID: UInt32, width: Double, height: Double, fencePayload: RemoteHostedPIPFencePayload, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func completeOperation(presentationID: String, operationID: UInt64, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func willEndStream(presentationID: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func invalidatePresentation(id: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func noteInteraction(presentationID: String, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
    func setComputerUseCursorLocation(x: Double, y: Double, isActive: Bool, reply: @escaping RemoteHostedPIPReply) { reply(nil) }
}
