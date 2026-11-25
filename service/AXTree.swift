import AppKit
import ApplicationServices

struct AXReference: Hashable {
    let element: AXUIElement
    static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
    func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

final class AXIndex {
    static let shared = AXIndex()
    final class State {
        var store = TreeRevisionStore<AXReference>()
        var scopes: [AXReference: String] = [:]
        var processKey = ""
        var snapshot: AXSnapshot?
        var nativeOwner: NativeAutomationTree?
        var retainedImages = Set<String>()
        var coordinateProcessKey: String?
        var coordinateLayout = ScreenshotGeometry.NativeLayout.uninitialized
        var nativeCursorPosition = CGPoint.zero
        var coordinateGeneration = UUID()
        func scope(_ element: AXUIElement) -> String {
            let reference = AXReference(element: element)
            if let existing = scopes[reference] { return existing }
            let key = UUID().uuidString; scopes[reference] = key; return key
        }
    }
    private var states: [String: State] = [:]
    private var shuttingDown = false
    private let lock = NSLock()

    func state(_ bundle: String) -> State {
        lock.lock(); defer { lock.unlock() }
        if let state = states[bundle] { return state }
        let state = State(); states[bundle] = state; return state
    }
    func snapshot(for bundle: String) -> AXSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return states[bundle]?.snapshot
    }

    struct CoordinateLease {
        fileprivate let bundle: String
        fileprivate let processKey: String
        fileprivate let state: State
        fileprivate let generation: UUID
    }

    func prepareNativeCoordinates(for bundle: String, processKey: String) throws -> CoordinateLease {
        try lock.withLock {
            guard !shuttingDown else { throw ServiceError(.noActiveSession, "Capture owner is shutting down") }
            let state = states[bundle] ?? State()
            states[bundle] = state
            if state.coordinateProcessKey != processKey {
                Self.clearNativeCoordinates(state)
                state.coordinateProcessKey = processKey
            }
            // A timed-out image producer cannot overwrite the next attempt.
            state.coordinateGeneration = UUID()
            return CoordinateLease(bundle: bundle, processKey: processKey, state: state,
                                   generation: state.coordinateGeneration)
        }
    }

    func updateNativeCoordinates(_ layout: ScreenshotGeometry.NativeLayout, lease: CoordinateLease,
                                 isRunning: () -> Bool) throws {
        try lock.withLock {
            guard !shuttingDown, let state = states[lease.bundle], state === lease.state,
                  state.coordinateProcessKey == lease.processKey,
                  state.coordinateGeneration == lease.generation, isRunning() else {
                throw ServiceError(.noActiveSession, "Native coordinate owner changed during capture")
            }
            state.coordinateLayout = layout
        }
    }

    func nativeCoordinates(for bundle: String, processKey: String) -> ScreenshotGeometry.NativeLayout? {
        lock.withLock {
            guard !shuttingDown, let state = states[bundle], state.coordinateProcessKey == processKey else { return nil }
            return state.coordinateLayout
        }
    }

    func updateNativeCursor(_ point: CGPoint, for bundle: String, processKey: String) throws {
        try lock.withLock {
            guard !shuttingDown, let state = states[bundle], state.coordinateProcessKey == processKey else {
                throw ServiceError(.noActiveSession, "Native coordinate owner changed during interaction")
            }
            state.nativeCursorPosition = point
        }
    }

    func nativePointerState(for bundle: String, processKey: String) -> (layout: ScreenshotGeometry.NativeLayout, position: CGPoint)? {
        lock.withLock {
            guard !shuttingDown, let state = states[bundle], state.coordinateProcessKey == processKey else { return nil }
            return (state.coordinateLayout, state.nativeCursorPosition)
        }
    }

    private static func clearNativeCoordinates(_ state: State) {
        state.coordinateProcessKey = nil
        state.coordinateLayout = .uninitialized
        state.nativeCursorPosition = .zero
        state.coordinateGeneration = UUID()
    }
    func publish(_ snapshot: AXSnapshot, retainImage: Bool, isRunning: () -> Bool) throws {
        let expired = try lock.withLock {
            guard !shuttingDown, isRunning() else {
                throw ServiceError(.runningApplicationNotFound, "Application exited during capture")
            }
            let state = states[snapshot.bundleIdentifier] ?? State()
            states[snapshot.bundleIdentifier] = state
            var expired = Set<String>()
            if state.snapshot?.processKey != snapshot.processKey {
                if state.coordinateProcessKey != snapshot.processKey { Self.clearNativeCoordinates(state) }
                expired = Self.releaseImages(state)
            }
            if retainImage, let path = snapshot.screenshotPath { state.retainedImages.insert(path) }
            if let path = state.snapshot?.screenshotPath, path != snapshot.screenshotPath,
               !state.retainedImages.contains(path) { expired.insert(path) }
            state.snapshot = snapshot
            return expired
        }
        for path in expired { Capture.removeTemporaryImage(path) }
    }
    func invalidate(_ bundle: String) {
        let expired = lock.withLock { () -> Set<String> in
            guard let state = states[bundle] else { return [] }
            state.store.invalidate()
            state.scopes.removeAll()
            Self.clearNativeCoordinates(state)
            return Self.releaseImages(state)
        }
        for path in expired { Capture.removeTemporaryImage(path) }
    }
    func applicationTerminated(processKey: String) {
        let expired = lock.withLock {
            states.values.filter { $0.snapshot?.processKey == processKey || $0.coordinateProcessKey == processKey }.flatMap { state in
                Self.clearNativeCoordinates(state)
                return Self.releaseImages(state)
            }
        }
        for path in expired { Capture.removeTemporaryImage(path) }
    }
    func shutdown() {
        let expired = lock.withLock {
            shuttingDown = true
            return states.values.flatMap { state in
                Self.clearNativeCoordinates(state)
                return Self.releaseImages(state)
            }
        }
        for path in expired { Capture.removeTemporaryImage(path) }
    }

    // The lock owns snapshot and file lifetime. AX tree state remains on the app gate.
    private static func releaseImages(_ state: State) -> Set<String> {
        var expired = state.retainedImages
        if let path = state.snapshot?.screenshotPath { expired.insert(path) }
        state.snapshot = nil
        state.retainedImages.removeAll()
        return expired
    }

    func element(_ index: String, for bundle: String, ignoreValueChange: Bool = false) throws -> AXUIElement {
        try RequestRuntime.serialized(app: bundle) {
            guard let id = Int(index), id >= 0, String(id) == index else {
                throw ServiceError(.accessibilityError, "Invalid accessibility element ID")
            }
            guard let observed = snapshot(for: bundle) else { throw ServiceError(.noActiveSession, "Read app state before using element IDs") }
            let app = try AppResolver.require(bundle)
            guard AXCapture.processKey(app) == observed.processKey else {
                throw ServiceError(.noActiveSession, "Application restarted; read app state again")
            }
            if let native = observed.nativeTree {
                return try NativeAutomationTree.onMain {
                    guard let owner = self.state(bundle).nativeOwner else {
                        throw ServiceError(.noActiveSession, "Native capture owner is unavailable")
                    }
                    return try owner.resolve(id, in: native, app: app, ignoreValueChange: ignoreValueChange).element
                }
            }
            guard let expected = observed.revision?.entry(id) else {
                throw ServiceError(.accessibilityError, "Element ID is not part of the latest observation")
            }
            let element = expected.reference.element
            // Only rebuild when the monitor observed invalidation.
            if let monitor = observed.invalidationMonitor, !monitor.requiresRefetch(element) {
                var role: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                if !monitor.requiresRefetch(element) {
                    guard status != .invalidUIElement else {
                        throw ServiceError(.accessibilityError, "Accessibility element was invalidated; read app state again")
                    }
                    try RequestRuntime.check()
                    return element
                }
            }
            let state = state(bundle), read = try AXTreeReader.read(app: app, state: state, native: observed.native)
            var preview = state.store
            let revision = try preview.update(session: observed.processKey, sections: read.sections, nodes: read.nodes,
                                              appName: app.displayName, forceFull: true, truncated: read.truncated,
                                              check: RequestRuntime.check)
            let candidate = try revision.validatedElement(expected: expected, ignoreValueChange: ignoreValueChange)
            try RequestRuntime.check()
            return candidate.reference.element
        }
    }
    func nativeSecondary(_ index: String, for bundle: String) throws -> (element: AXUIElement, actions: [EventStreamNodeAction], windowID: UInt32)? {
        try RequestRuntime.serialized(app: bundle) {
            guard let observed = snapshot(for: bundle), let native = observed.nativeTree else { return nil }
            guard let id = Int(index), id >= 0, String(id) == index else {
                throw ServiceError(.accessibilityError, "Invalid accessibility element ID")
            }
            let app = try AppResolver.require(bundle)
            guard AXCapture.processKey(app) == observed.processKey else {
                throw ServiceError(.noActiveSession, "Application restarted; read app state again")
            }
            return try NativeAutomationTree.onMain {
                guard let owner = state(bundle).nativeOwner else {
                    throw ServiceError(.noActiveSession, "Native capture owner is unavailable")
                }
                let resolved = try owner.resolve(id, in: native, app: app, ignoreValueChange: false)
                return (resolved.element, resolved.node.actionDescriptions, resolved.snapshot.selection.applicationWindow.nativeWindow.id)
            }
        }
    }

    func nativeSelection(_ index: String, for bundle: String, text: String, prefix: String?, suffix: String?,
                         selection: String) throws -> (element: AXUIElement, range: NSRange, window: EventStreamNativeWindow)? {
        try RequestRuntime.serialized(app: bundle) {
            guard let observed = snapshot(for: bundle), let native = observed.nativeTree else { return nil }
            guard let id = Int(index), id >= 0, String(id) == index else {
                throw ServiceError(.accessibilityError, "Invalid accessibility element ID")
            }
            let app = try AppResolver.require(bundle)
            guard AXCapture.processKey(app) == observed.processKey else {
                throw ServiceError(.noActiveSession, "Application restarted; read app state again")
            }
            return try NativeAutomationTree.onMain {
                guard let owner = state(bundle).nativeOwner else {
                    throw ServiceError(.noActiveSession, "Native capture owner is unavailable")
                }
                let resolved = try owner.resolve(id, in: native, app: app, ignoreValueChange: true)
                try AX.requireTextSelectionSettable(resolved.element)
                return (resolved.element, try resolved.snapshot.sourceRange(for: resolved.id, text: text,
                    prefix: prefix, suffix: suffix, selection: selection), resolved.snapshot.selection.applicationWindow.nativeWindow)
            }
        }
    }
}

struct AXTreeReader {
    private enum ReadError: Error { case invalidated }
    private(set) var nodes: [TreeNode<AXReference>] = []
    private(set) var sections: [TreeSection] = []
    private(set) var truncated = false
    private var seen = Set<AXReference>()
    let window: AXUIElement?
    let title: String
    let origin: CGPoint
    let size: CGSize
    private(set) var isMenu = false
    private(set) var nativeCaptureTarget: PointerTarget?

    static func description(_ element: AXUIElement, cachedRole: String? = nil) throws -> ElementDescription {
        guard let role = cachedRole ?? AX.string(element, kAXRoleAttribute as String) else { throw ReadError.invalidated }
        var value = ElementDescription(role: role)
        value.subrole = AX.string(element, kAXSubroleAttribute as String)
        value.identifier = AX.string(element, kAXIdentifierAttribute as String)
        value.title = AX.string(element, kAXTitleAttribute as String)
        if let raw = AX.copy(element, kAXValueAttribute as String) {
            value.value = (raw as? String) ?? (raw as? NSNumber)?.stringValue ?? (raw as? NSAttributedString)?.string
        }
        value.detail = AX.string(element, kAXDescriptionAttribute as String)
        value.help = AX.string(element, kAXHelpAttribute as String)
        if let url = AX.copy(element, kAXURLAttribute as String) as? URL { value.url = url.absoluteString }
        value.enabled = AX.copy(element, kAXEnabledAttribute as String) as? Bool
        value.actions = AX.actionNames(element)
        if let p = AX.point(element, kAXPositionAttribute as String), let s = AX.size(element, kAXSizeAttribute as String) {
            value.frame = ElementFrame(x: p.x, y: p.y, width: s.width, height: s.height)
        }
        return value
    }

    static func read(app: ResolvedApp, state: AXIndex.State, native: Bool, waitForQuiet: Bool = true,
                     bindNativeWindow: Bool = false) throws -> Self {
        for attempt in 0..<2 {
            do {
                return try readOnce(app: app, state: state, native: native, waitForQuiet: waitForQuiet,
                                    bindNativeWindow: bindNativeWindow)
            }
            catch ReadError.invalidated {
                if attempt == 1 { throw ServiceError(.accessibilityError, "Accessibility tree changed during the scan; read app state again") }
            }
        }
        throw ServiceError(.accessibilityError, "Could not read accessibility tree")
    }

    static func readSettled(app: ResolvedApp, state: AXIndex.State, settled: AXSettledWindow) throws -> Self? {
        let process = AXCapture.processKey(app)
        guard settled.isCurrent(processKey: process, window: settled.root.element) else { return nil }
        do {
            let read = try readOnce(app: app, state: state, native: true, waitForQuiet: false,
                                    bindNativeWindow: true, settled: settled)
            guard settled.isCurrent(processKey: process, window: read.window) else { return nil }
            return read
        } catch ReadError.invalidated { return nil }
    }

    /// Appshot reads the selected window without publishing automation IDs or
    /// changing AXIndex. Capture and text retain the same window identity.
    static func captureText(window: AXUIElement, app: ResolvedApp) throws -> String {
        try Permissions.requireUnlockedScreen()
        try RequestRuntime.check()
        let key = AXCapture.processKey(app)
        guard let origin = AX.point(window, kAXPositionAttribute as String),
              let size = AX.size(window, kAXSizeAttribute as String) else {
            throw ServiceError(.accessibilityError, "Capture window is no longer accessible")
        }
        var read = Self(window: window, title: AX.string(window, kAXTitleAttribute as String) ?? app.displayName, origin: origin, size: size)
        do { try read.visit(window, parent: nil, section: "capture", depth: 0) }
        catch { throw ServiceError(.accessibilityError, "Capture window changed while reading its content") }
        guard !app.running.isTerminated, key == AXCapture.processKey(app) else {
            throw ServiceError(.runningApplicationNotFound, "Application exited during capture")
        }
        var depths: [Int] = [], lines: [String] = []
        for node in read.nodes {
            try RequestRuntime.check()
            let depth = node.parent.map { depths[$0] + 1 } ?? 0
            depths.append(depth)
            lines.append(node.description.line(id: 0, depth: depth, includeElementID: false))
        }
        if read.truncated { lines.append("Accessibility content was truncated.") }
        return lines.joined(separator: "\n")
    }

    private static func readOnce(app: ResolvedApp, state: AXIndex.State, native: Bool, waitForQuiet: Bool,
                                 bindNativeWindow: Bool, settled: AXSettledWindow? = nil) throws -> Self {
        try Permissions.requireUnlockedScreen()
        let process = AXCapture.processKey(app)
        if state.processKey != process { state.scopes.removeAll(); state.processKey = process }
        let pid = app.running.processIdentifier, element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 1)
        if waitForQuiet { try AXSettler.wait(app: element, pid: pid) }
        let menu = native ? AXMenuSessions.root(for: app, application: element) : nil
        var ordered: [AXUIElement] = []
        if menu == nil {
            for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let window = AX.axElement(AX.copy(element, attribute as String)), !ordered.contains(where: { CFEqual($0, window) }) { ordered.append(window) }
            }
            let windows = (AX.copy(element, kAXWindowsAttribute as String) as? [AnyObject])?.compactMap { AX.axElement($0) } ?? []
            if native, ordered.isEmpty, let primary = windows.last { ordered.append(primary) }
            for window in windows where !ordered.contains(where: { CFEqual($0, window) }) { ordered.append(window) }
        }
        let window = ordered.first
        if let settled, !settled.isCurrent(processKey: process, window: window) { throw ReadError.invalidated }
        var captureTarget: PointerTarget?
        if bindNativeWindow, menu == nil {
            guard let window else { throw ServiceError(.accessibilityError, "Application has no accessible capture window") }
            try StageManagerCapture.prepare(window)
            captureTarget = try Capture.nativeWindowTarget(window, appPID: pid)
        }
        var reader = Self(window: window, title: window.flatMap { AX.string($0, kAXTitleAttribute as String) } ?? app.displayName,
                          origin: window.flatMap { AX.point($0, kAXPositionAttribute as String) } ?? .zero,
                          size: window.flatMap { AX.size($0, kAXSizeAttribute as String) } ?? CGSize(width: 1440, height: 900))
        reader.isMenu = menu != nil
        reader.nativeCaptureTarget = captureTarget
        var roots = menu.map { [$0] } ?? (ordered.isEmpty ? [element] : ordered)
        if native, menu == nil, let menuBar = AX.axElement(AX.copy(element, kAXMenuBarAttribute as String)) {
            roots.append(menuBar)
        }
        for root in roots where !reader.seen.contains(AXReference(element: root)) {
            let section = state.scope(root)
            reader.sections.append(TreeSection(key: section, title: AX.string(root, kAXTitleAttribute as String) ?? app.displayName))
            let cachedRoot = settled.flatMap { $0.root == AXReference(element: root) ? $0 : nil }
            try reader.visit(root, parent: nil, section: section, depth: 0, settled: cachedRoot)
        }
        // An internal recovery scan must not retire a published window's
        // namespace merely because that window was temporarily unavailable.
        let retained = Set(reader.sections.map(\.key)).union(state.store.current?.sections.map(\.key) ?? [])
        state.scopes = state.scopes.filter { retained.contains($0.value) }
        guard !app.running.isTerminated, AXCapture.processKey(app) == process else {
            throw ServiceError(.noActiveSession, "Application exited during accessibility scan")
        }
        return reader
    }

    private mutating func visit(_ element: AXUIElement, parent: Int?, section: String, depth: Int,
                                settled: AXSettledWindow? = nil) throws {
        try RequestRuntime.check()
        guard nodes.count < 5000, depth < 60 else { truncated = true; return }
        let reference = AXReference(element: element)
        guard seen.insert(reference).inserted else { return }
        let index = nodes.count
        let description = try Self.description(element, cachedRole: settled?.roles[reference])
        nodes.append(TreeNode(reference: reference, description: description, parent: parent, section: section))
        for child in settled?.children[reference] ?? AX.children(element) {
            try visit(child, parent: index, section: section, depth: depth + 1, settled: settled)
        }
    }
}

enum AXCapture {
    static func processKey(_ app: ResolvedApp) -> String {
        AppResolver.processKey(app.running)
    }
    static func capture(app identifier: String, disableDiff: Bool, native: Bool) throws -> AXSnapshot {
        try NativeTargetPolicy.requireAllowed(identifier)
        try Permissions.requireAccessibility()
        let bundle = try AppResolver.targetIdentifier(identifier)
        try NativeTargetPolicy.requireAllowed(bundle)
        try AppSessions.shared.validateStart(bundle, allowRequery: true)
        try Permissions.requireUnlockedScreen()
        try UserInteractionMonitor.shared.ensureRunning()
        if try AppResolver.find(identifier) == nil { try AppResolver.activate(identifier) }
        let app = try AppResolver.require(identifier)
        try NativeTargetPolicy.requireAllowed(app.bundleIdentifier)
        return try RequestRuntime.serialized(app: app.bundleIdentifier) {
            let token = try AppSessions.shared.prepare(app: app.ipc, process: processKey(app), create: true, requery: true)
            return try RequestRuntime.withCheckpoint({ try AppSessions.shared.check(token, requery: true) }) {
                let settle = native ? try AppSessions.shared.exchangeSettling(false, for: token, requery: true) : false
                return try captureCurrent(app: app, disableDiff: disableDiff, enforceURLPolicy: native,
                                          native: native, settleBeforeCapture: settle) {
                    try AppSessions.shared.didRequery(token)
                }
            }
        }
    }

    // The caller holds the per-app gate and the appropriate session checkpoint.
    // Action captures use the existing process and never relaunch the app.
    static func captureCurrent(app: ResolvedApp, disableDiff: Bool, enforceURLPolicy: Bool = false,
                               native: Bool, settled: AXSettledWindow? = nil, settleBeforeCapture: Bool = false,
                               beforePublish: () throws -> Void = {}) throws -> AXSnapshot {
        let state = AXIndex.shared.state(app.bundleIdentifier)
        if native {
            AXMenuSessions.observe(app)
            return try captureNativeCurrent(app: app, state: state, disableDiff: disableDiff,
                enforceURLPolicy: enforceURLPolicy, settled: settled, settleBeforeCapture: settleBeforeCapture,
                beforePublish: beforePublish)
        }
        var invalidationMonitor: EventStreamTreeInvalidationMonitor?
        let read: AXTreeReader = try {
            guard native else { return try AXTreeReader.read(app: app, state: state, native: false) }
            let accessibility = AXAccessibility.acquire(for: app)
            defer { accessibility?.release() }
            try RequestRuntime.check()
            AXMenuSessions.observe(app)
            let candidate = settleBeforeCapture
                ? try AXSettler.waitForNativeCapture(app: app)
                : settled
            if let candidate, let read = try AXTreeReader.readSettled(app: app, state: state, settled: candidate) {
                invalidationMonitor = candidate.monitor
                return read
            }
            invalidationMonitor = EventStreamTreeInvalidationMonitor(
                application: AXUIElementCreateApplication(app.running.processIdentifier))
            return try AXTreeReader.read(app: app, state: state, native: true, waitForQuiet: false, bindNativeWindow: true)
        }()
        var store = state.store
        let process = processKey(app)
        let revision = try store.update(session: process, sections: read.sections, nodes: read.nodes,
                                        appName: app.displayName, forceFull: disableDiff, truncated: read.truncated,
                                        check: RequestRuntime.check)
        let cursor = Actions.cursorForCapture(app.bundleIdentifier)
        let cursorWindows = cursor.map { [$0.windowID] } ?? []
        let captured = try captureImage(native: native, menuFocused: read.isMenu) {
            var pid = app.running.processIdentifier
            var nativeAppName: String?
            let reference: Capture.WindowReference?
            if native {
                guard let target = read.nativeCaptureTarget else {
                    throw ServiceError(.accessibilityError, "Application has no accessible capture window")
                }
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 1)
                nativeAppName = AX.string(element, kAXTitleAttribute as String) ?? "Unknown"
                pid = target.ownerPID
                reference = Capture.WindowReference(frame: target.screenFrame, title: nil, windowID: target.windowID)
            } else {
                reference = read.window.map { Capture.WindowReference(frame: CGRect(origin: read.origin, size: read.size),
                                                                       title: AX.string($0, kAXTitleAttribute as String)) }
            }
            let image = try Capture.captureWindow(pid: pid, into: nil, matching: reference,
                                                  additionalWindowIDs: cursorWindows, nativeAppName: nativeAppName)
            if let cursor, !Actions.cursorIsCurrent(cursor, for: app.bundleIdentifier) {
                Capture.removeTemporaryImage(image.path.path)
                throw ServiceError(.accessibilityError, "Cursor ownership changed during capture; read app state again")
            }
            return image
        }
        var published = false
        defer { if !published { Capture.removeTemporaryImage(captured?.path.path) } }
        if enforceURLPolicy {
            let section = read.sections.first?.key
            let webAreaURL = read.nodes.first {
                $0.section == section && $0.description.role == "AXWebArea" && $0.description.url != nil
            }?.description.url
            try ActionAppSnapshotURLPolicy.check(webAreaURL, for: app)
        }
        try RequestRuntime.check()
        let snapshot = AXSnapshot(app: app.displayName, bundleIdentifier: app.bundleIdentifier, text: revision.text,
                                  windowOrigin: read.origin, windowSize: read.size, windowTitle: read.title,
                                  screenshotPath: captured?.path.path, geometry: captured?.geometry, windowElement: read.window,
                                  processKey: process, revision: revision, appReference: app.ipc, native: native,
                                  invalidationMonitor: invalidationMonitor)
        try beforePublish()
        try AXIndex.shared.publish(snapshot, retainImage: native) { !app.running.isTerminated }
        published = true
        state.store = store
        let retained = Set(read.sections.map(\.key))
        state.scopes = state.scopes.filter { retained.contains($0.value) }
        return snapshot
    }

    private static func captureNativeCurrent(app: ResolvedApp, state: AXIndex.State, disableDiff: Bool,
                                             enforceURLPolicy: Bool, settled: AXSettledWindow?,
                                             settleBeforeCapture: Bool, beforePublish: () throws -> Void) throws -> AXSnapshot {
        try Permissions.requireUnlockedScreen()
        try RequestRuntime.check()
        let coordinateLease = try AXIndex.shared.prepareNativeCoordinates(for: app.bundleIdentifier, processKey: processKey(app))
        let application = AXUIElementCreateApplication(app.running.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 1)
        let candidate = settleBeforeCapture ? try AXSettler.waitForNativeCapture(app: app) : settled
        let window = candidate.flatMap { $0.isCurrent(processKey: processKey(app), window: $0.root.element) ? $0.root.element : nil }
            ?? AX.primaryWindow(application)
        guard let window else { throw ServiceError(.accessibilityError, "Application has no accessible capture window") }
        try StageManagerCapture.prepare(window)
        let menu = AXMenuSessions.root(for: app, application: application)
        let tree = try NativeAutomationTree.onMain {
            let owner = state.nativeOwner ?? NativeAutomationTree()
            state.nativeOwner = owner
            return try owner.capture(app: app, window: window, previous: state.snapshot?.nativeTree,
                                     rootOverride: menu, disableDiff: disableDiff)
        }
        let target = try Capture.nativeWindowTarget(window, appPID: app.running.processIdentifier)
        let cursor = Actions.cursorForCapture(app.bundleIdentifier)
        let image = try captureImage(native: true, menuFocused: menu != nil) {
            // Update geometry before the image attempt. Image-less menus keep the preceding plan.
            let plan = try Capture.nativeGeometryPlan(frame: target.screenFrame)
            try AXIndex.shared.updateNativeCoordinates(plan.layout, lease: coordinateLease) { !app.running.isTerminated }
            return try Capture.captureWindow(pid: target.ownerPID, into: nil,
                matching: .init(frame: target.screenFrame, title: nil, windowID: target.windowID),
                additionalWindowIDs: cursor.map { [$0.windowID] } ?? [],
                nativeAppName: AX.string(application, kAXTitleAttribute as String) ?? "Unknown", nativePlan: plan)
        }
        var published = false
        defer { if !published { Capture.removeTemporaryImage(image?.path.path) } }
        if image != nil, let cursor, !Actions.cursorIsCurrent(cursor, for: app.bundleIdentifier) {
            throw ServiceError(.accessibilityError, "Cursor ownership changed during capture; read app state again")
        }
        if enforceURLPolicy {
            let selectedURL = try NativeAutomationTree.onMain { tree.selection.url?.absoluteString }
            try ActionAppSnapshotURLPolicy.check(selectedURL, for: app)
        }
        try RequestRuntime.check()
        let snapshot = AXSnapshot(app: app.displayName, bundleIdentifier: app.bundleIdentifier, text: tree.text,
            windowOrigin: target.screenFrame.origin, windowSize: target.screenFrame.size,
            windowTitle: AX.string(window, kAXTitleAttribute as String) ?? app.displayName,
            screenshotPath: image?.path.path, geometry: image?.geometry, windowElement: window,
            processKey: processKey(app), appReference: app.ipc, native: true, nativeTree: tree,
            invalidationMonitor: try NativeAutomationTree.onMain { tree.selection.invalidationMonitor })
        try beforePublish()
        try AXIndex.shared.publish(snapshot, retainImage: true) { !app.running.isTerminated }
        published = true
        return snapshot
    }

    static func captureImage(native: Bool, menuFocused: Bool = false, _ capture: () throws -> Capture.Captured) throws -> Capture.Captured? {
        if menuFocused { return nil }
        do { return try capture() }
        catch {
            if native { throw error }
            if ProcessInfo.processInfo.environment["ACUA_DIAGNOSTICS"] == "1" {
                FileHandle.standardError.write(Data("Screenshot failed: \(error)\n".utf8))
            }
            return nil
        }
    }
}
