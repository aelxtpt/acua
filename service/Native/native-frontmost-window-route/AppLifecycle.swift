import AppKit
import ApplicationServices

enum AppLifecycle {
    static func listApps() throws -> [JSON] {
        let responsibleBundle = RequestRuntime.senderContext?.responsibleIdentity?.bundleID
        let frontmostPID = frontmostApplication(excluding: [getpid()],
                                                bundles: Set([responsibleBundle].compactMap { $0 }))?.processIdentifier
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> AppUsageCatalog.Entry? in
            guard app.activationPolicy == .regular, let id = app.bundleIdentifier, !id.isEmpty else { return nil }
            return .init(displayName: app.localizedName ?? id, bundleIdentifier: id, appPath: AppUsageCatalog.runningAppPath(app.bundleURL),
                         isRunning: true, isFrontmost: app.processIdentifier == frontmostPID, pid: app.processIdentifier)
        }
        let indexed = AppUsageCatalog.includingRunningFallbacks(AppUsageCatalog.shared.snapshot(), running: running)
        try RequestRuntime.check()
        return AppUsageCatalog.merge(running: running, indexed: indexed).map(\.json)
    }

    static func start(_ identifier: String, native: Bool) throws -> JSON {
        try NativeTargetPolicy.requireAllowed(identifier)
        let bundle = try AppResolver.targetIdentifier(identifier)
        try NativeTargetPolicy.requireAllowed(bundle)
        return try RequestRuntime.serialized(app: bundle) {
            try AppSessions.shared.validateStart(bundle)
            try Permissions.requireUnlockedScreen()
            try Permissions.requireAccessibility()
            try UserInteractionMonitor.shared.ensureRunning()
            try AppResolver.activate(identifier)
            let app = try AppResolver.require(bundle)
            let token = try AppSessions.shared.prepare(app: app.ipc, process: AXCapture.processKey(app), create: true)
            let state = try AppSessions.shared.activate(token)
            if native { AXMenuSessions.observe(app, holdAccessibility: true) }
            return state.json
        }
    }
    static func stop(_ identifier: String) throws -> JSON {
        try NativeTargetPolicy.requireAllowed(identifier)
        let bundle = try AppResolver.targetIdentifier(identifier)
        try NativeTargetPolicy.requireAllowed(bundle)
        // Mark before waiting on the app queue, so held input can observe the
        // stop and run its release cleanup instead of making stop wait forever.
        let state = AppSessions.shared.stop(bundle)
        return try RequestRuntime.serialized(app: bundle) {
            SyntheticFocusSessions.end(bundle)
            AXMenuSessions.end(bundle)
            AXIndex.shared.invalidate(bundle)
            Actions.hideCursor(for: bundle)
            return state.json
        }
    }
    static func modify(_ identifier: String, modification: JSON, native: Bool) throws -> JSON {
        guard modification.count == 1, let operation = modification.keys.first,
              ["activate", "deactivate"].contains(operation), let payload = asDict(modification[operation]), payload.isEmpty else {
            throw ServiceError(.couldNotGetRequestData, "Expected activate:{} or deactivate:{} modification")
        }
        try NativeTargetPolicy.requireAllowed(identifier)
        let app = try AppResolver.require(identifier), bundle = app.bundleIdentifier
        try NativeTargetPolicy.requireAllowed(bundle)
        return try RequestRuntime.serialized(app: bundle) {
            let current = try AppResolver.require(bundle)
            let token = try AppSessions.shared.prepare(app: current.ipc, process: AXCapture.processKey(current), create: false, requery: operation == "deactivate")
            if operation == "activate" {
                try Permissions.requireUnlockedScreen()
                let state = try AppSessions.shared.activate(token)
                if native { AXMenuSessions.observe(current, holdAccessibility: true) }
                return state.json
            }
            let state = try AppSessions.shared.deactivate(token)
            SyntheticFocusSessions.end(bundle)
            AXMenuSessions.end(bundle)
            AXIndex.shared.invalidate(bundle)
            Actions.hideCursor(for: bundle)
            return state.json
        }
    }
    static func frontmostApplication(excluding excluded: Set<pid_t>,
                                     bundles excludedBundles: Set<String>) -> NSRunningApplication? {
        func isCandidate(_ app: NSRunningApplication) -> Bool {
            guard let bundle = app.bundleIdentifier, !bundle.isEmpty else { return false }
            return !excluded.contains(app.processIdentifier) && !excludedBundles.contains(bundle)
        }
        var application = NSWorkspace.shared.frontmostApplication
        if application.map(isCandidate) != true {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            let menuLevel = CGWindowLevelForKey(.mainMenuWindow)
            application = windows.lazy.compactMap { info -> NSRunningApplication? in
                guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                      let layer = (info[kCGWindowLayer as String] as? NSNumber)?.int32Value, layer < menuLevel,
                      let app = NSRunningApplication(processIdentifier: pid), isCandidate(app),
                      app.activationPolicy == .regular, !app.isHidden else { return nil }
                return app
            }.first
        }
        return application
    }

    static func frontmostWindow() throws -> JSON? {
        try frontmostWindow(environment:ControllerFrontmostWindowNative.environment)
    }
    static func frontmostWindow<A:Sendable,N:Sendable>(environment:ControllerFrontmostWindow<A,N>.Environment) throws -> JSON? {
        ControllerFrontmostWindow<A,N>(environment:environment).read(sender:RequestRuntime.senderContext)?.json
    }
}
