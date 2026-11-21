import AppKit
import ApplicationServices

enum StageManagerCapture {
    private static let managerBundle = "com.apple.WindowManager"

    static func prepare(_ window: AXUIElement) throws {
        guard UserDefaults(suiteName: managerBundle)?.bool(forKey: "GloballyEnabled") == true else { return }
        try RequestRuntime.check()
        guard let manager = NSRunningApplication.runningApplications(withBundleIdentifier: managerBundle).first else {
            throw ServiceError(.accessibilityError, "Stage Manager process is unavailable")
        }
        guard let id = try? AccessibilityWindowSPI.windowID(window) else { return }
        let root = AXUIElementCreateApplication(manager.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
        var targetPID: pid_t = 0
        _ = AXUIElementGetPid(window, &targetPID)
        try revealIfOffstage(find: {
            try entry(for: id, root: AXReference(element: root), windowIDs: { node in
                guard let values = AX.copy(node.element, "AXWindowsIDs") as? [Any] else { return [] }
                let ids = values.compactMap { intValue($0).flatMap(UInt32.init(exactly:)) }
                return ids.count == values.count ? ids : []
            }, children: { AX.children($0.element).prefix(100).map { AXReference(element: $0) } },
               check: RequestRuntime.check)
        }, beforeReveal: {
            try RequestRuntime.check()
            try Permissions.requireUnlockedScreen()
            preserveForeground(targetPID: targetPID)
        }, unminimize: {
            let status = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            guard status == .success else {
                throw ServiceError(.accessibilityError, "Could not unminimize the Stage Manager window (\(status.rawValue))")
            }
        }, wait: { try RequestRuntime.wait(0.05) }, add: { node in
            try RequestRuntime.check()
            try Permissions.requireUnlockedScreen()
            let status = AXUIElementPerformAction(node.element, "AXAddToStage" as CFString)
            guard status == .success else {
                throw ServiceError(.accessibilityError, "Could not add the window to Stage Manager (\(status.rawValue))")
            }
        })
    }

    static func entry<Node: Hashable>(for id: UInt32, root: Node, windowIDs: (Node) -> [UInt32],
                                      children: (Node) -> [Node], check: () throws -> Void) rethrows -> Node? {
        var pending = [root], visited = Set<Node>()
        while let node = pending.popLast(), visited.count < 5000 {
            try check()
            guard visited.insert(node).inserted else { continue }
            if windowIDs(node).contains(id) { return node }
            pending.append(contentsOf: children(node).reversed())
        }
        return nil
    }

    static func revealIfOffstage<Node>(find: () throws -> Node?, beforeReveal: () throws -> Void,
                                       unminimize: () throws -> Void, wait: () throws -> Void,
                                       add: (Node) throws -> Void) rethrows {
        guard try find() != nil else { return }
        try beforeReveal()
        try unminimize()
        try wait()
        if let entry = try find() { try add(entry) }
    }

    private static func preserveForeground(targetPID: pid_t) {
        let workspace = NSWorkspace.shared
        guard targetPID > 0, let previous = workspace.frontmostApplication,
              previous.processIdentifier != targetPID else { return }
        let deadline = DispatchTime.now() + .milliseconds(300)
        let center = workspace.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            guard let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  activated.processIdentifier == targetPID else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) {
                guard DispatchTime.now() <= deadline, !Permissions.screenLocked(), !previous.isTerminated,
                      workspace.frontmostApplication?.processIdentifier == targetPID else { return }
                _ = previous.activate(options: [])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: deadline) { center.removeObserver(token) }
    }
}
