import AppKit
import CoreGraphics
import Foundation

final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[UInt32]] = []
    func add(_ window: CGWindowID, _ event: RemoteHostedPIPWindowServerObserver.Event) {
        lock.withLock { entries.append([window, event.rawValue]) }
    }
    var all: [[UInt32]] { lock.withLock { entries } }
}

@main enum NativeWindowServerOrderTest {
    @MainActor static func main() {
        let app = NSApplication.shared
        guard app.activationPolicy() == .prohibited || app.setActivationPolicy(.prohibited) else {
            print("FAIL: could not prohibit fixture activation (policy \(app.activationPolicy().rawValue))")
            exit(2)
        }
        Task { @MainActor in
            exit(await run(app))
        }
        app.run()
    }

    @MainActor static func run(_ app: NSApplication) async -> Int32 {
        let previous = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let foregroundBefore = previous ?? -1
        func fixture(_ x: CGFloat) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: x, y: 20, width: 32, height: 32),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.backgroundColor = .clear
            window.isOpaque = false
            window.orderFrontRegardless()
            return window
        }
        func wait(_ seconds: Double) async {
            try? await Task.sleep(for: .seconds(seconds))
        }
        let a = fixture(20), b = fixture(58)
        defer { a.close(); b.close() }
        await wait(0.3)
        let aID = CGWindowID(a.windowNumber), bID = CGWindowID(b.windowNumber)
        let order = EventLog(), excluded = EventLog(), workspace = EventLog(), pip = EventLog()
        guard let orderObserver = RemoteHostedPIPWindowServerObserver(windowIDs: [aID], events: [.orderChanged], onEvent: { order.add($0, $1) }),
              let excludedObserver = RemoteHostedPIPWindowServerObserver(windowIDs: [bID], events: [.orderChanged], onEvent: { excluded.add($0, $1) }),
              let workspaceObserver = RemoteHostedPIPWindowServerObserver(windowIDs: nil, events: [.workspaceAddedWindow], onEvent: { workspace.add($0, $1) }),
              let pipObserver = RemoteHostedPIPWindowServerObserver(windowIDs: [aID], onEvent: { pip.add($0, $1) }) else {
            print("FAIL: subscriptions for fixture windows")
            exit(2)
        }
        let c = fixture(96)
        defer { c.close() }
        let cID = CGWindowID(c.windowNumber)
        for index in 0..<6 {
            a.order(index.isMultiple(of: 2) ? .above : .below, relativeTo: b.windowNumber)
            a.setFrame(NSRect(x: 20, y: 20, width: 34 + index, height: 34 + index), display: false)
            await wait(0.12)
        }
        await wait(0.6)
        let foregroundAfter = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        let ownIDs = Set([aID, bID, cID])
        let onScreen = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
            .filter { ownIDs.contains($0) }
        let output: [String: Any] = [
            "fixtureOnScreenIDs": onScreen, "appKitVisible": [a.isVisible, b.isVisible, c.isVisible],
            "pid": getpid(), "fixtures": [aID, bID, cID], "order": order.all, "otherOrder": excluded.all,
            "workspaceForFixture": workspace.all.filter { $0.first == cID },
            "workspaceDelivered": !workspace.all.isEmpty, "workspaceTotal": workspace.all.count, "pip": pip.all,
            "foregroundUnchanged": foregroundBefore == foregroundAfter && !app.isActive,
        ]
        withExtendedLifetime((orderObserver, excludedObserver, workspaceObserver, pipObserver)) {
            let json = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            print(String(decoding: json, as: UTF8.self))
        }
        let checks = [
            ("all fixture windows are present and the foreground is unchanged",
             Set(onScreen) == ownIDs && foregroundBefore == foregroundAfter && !app.isActive),
            ("order changes are delivered for the reordered window",
             !order.all.isEmpty && order.all.allSatisfy { $0 == [aID, 808] }),
            ("the other window's observer does not receive the reordered window", excluded.all.allSatisfy { $0 == [bID, 808] }),
            ("workspace addition delivers the created window ID", workspace.all.contains([cID, 1325])),
            ("PiP resize notifications still arrive on the shared connection", pip.all.contains([aID, 807])),
        ]
        for (label, passed) in checks { print("\(passed ? "PASS" : "FAIL") \(label)") }
        return checks.allSatisfy { $0.1 } ? 0 : 1
    }
}
