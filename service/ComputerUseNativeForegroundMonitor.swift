import AppKit
import ApplicationServices
import Carbon

@MainActor
final class ComputerUseNativeForegroundMonitor {
    private let workspace = NSWorkspace.shared
    private var activationObserver: NSObjectProtocol?
    private var activationID: UUID?
    private var permissionTask: Task<Void, Never>?
    private var axObserver: AXObserver?
    private var observedPID: pid_t?
    private var observedWindow: AXUIElement?
    private var readable = false
    private var needsSampling = false

    private(set) lazy var updates = ComputerUseForegroundUpdates(
        start: { [weak self] _ in self?.start() },
        stop: { [weak self] in self?.stop() })

    private func start() {
        let activationID = UUID()
        self.activationID = activationID
        activationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
        ) { [weak self] _ in
            let observedAt = Date()
            Task { @MainActor in
                guard let self, self.activationID == activationID else { return }
                self.sample(at: observedAt)
            }
        }
        sample(at: Date())
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                if self.readable != Self.canRead() || self.needsSampling {
                    self.sample(at: Date())
                }
            }
        }
    }

    func stop() {
        activationID = nil
        if let activationObserver { workspace.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        permissionTask?.cancel()
        permissionTask = nil
        clearObservation()
    }

    private static func canRead() -> Bool {
        Permissions.accessibilityGranted() && !IsSecureEventInputEnabled() && !Permissions.screenLocked()
    }

    private func sample(at date: Date) {
        readable = Self.canRead()
        guard readable, let app = workspace.frontmostApplication,
              app.activationPolicy == .regular, let bundle = app.bundleIdentifier else {
            clearObservation()
            updates.publish(nil, at: date)
            return
        }

        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let focused = AX.axElement(AX.copy(application, kAXFocusedWindowAttribute as String))
        let window = focused
            ?? AX.axElement(AX.copy(application, kAXMainWindowAttribute as String))
            ?? AX.axElement((AX.copy(application, kAXWindowsAttribute as String) as? [AnyObject])?.last)

        if observedPID != pid || !Self.sameWindow(observedWindow, window) {
            clearObservation()
            observedPID = pid
            observedWindow = window
            needsSampling = true
        }
        if needsSampling || focused == nil {
            register(application: application, window: window, pid: pid, hasFocusedWindow: focused != nil)
        }

        var title: String?
        var windowID: UInt32?
        if let window {
            AXUIElementSetMessagingTimeout(window, 0.2)
            var value: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value)
            if status == .success { title = value as? String }
            if status == .invalidUIElement || status == .cannotComplete { needsSampling = true }
            windowID = try? AccessibilityWindowSPI.windowID(window)
        }
        guard Self.canRead(), workspace.frontmostApplication?.processIdentifier == pid,
              !TimelinePrivateBrowsingIndicators.isPrivateBrowserWindow(bundleIdentifier: bundle, title: title) else {
            updates.publish(nil, at: date)
            return
        }
        updates.publish(.init(processIdentifier: pid, windowID: windowID, appName: app.localizedName ?? bundle,
                              bundleIdentifier: bundle, windowTitle: title), at: date)
    }

    private static func sameWindow(_ previous: AXUIElement?, _ current: AXUIElement?) -> Bool {
        guard let previous, let current else { return previous == nil && current == nil }
        return CFEqual(previous, current)
    }

    private func register(application: AXUIElement, window: AXUIElement?, pid: pid_t, hasFocusedWindow: Bool) {
        removeAXObserver()
        needsSampling = true
        var observer: AXObserver?
        let callback: AXObserverCallback = { source, _, _, context in
            guard let context else { return }
            let owner = Unmanaged<ComputerUseNativeForegroundMonitor>.fromOpaque(context).takeUnretainedValue()
            let observedAt = Date()
            MainActor.assumeIsolated { owner.accessibilityChanged(source, at: observedAt) }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let focus = AXObserverAddNotification(observer, application, kAXFocusedWindowChangedNotification as CFString, context)
        let main = AXObserverAddNotification(observer, application, kAXMainWindowChangedNotification as CFString, context)
        let created = AXObserverAddNotification(observer, application, kAXWindowCreatedNotification as CFString, context)
        let title = window.map { AXObserverAddNotification(observer, $0, kAXTitleChangedNotification as CFString, context) }
        func appNotificationFailed(_ result: AXError) -> Bool {
            result != .success && !(hasFocusedWindow && result == .notificationUnsupported)
        }
        needsSampling = focus != .success || title != .success || appNotificationFailed(main) || appNotificationFailed(created)
        axObserver = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    private func accessibilityChanged(_ source: AXObserver, at date: Date) {
        guard let axObserver, source === axObserver, let pid = observedPID else { return }
        Task { @MainActor [weak self] in
            guard let self, self.observedPID == pid else { return }
            self.sample(at: date)
        }
    }

    private func clearObservation() {
        removeAXObserver()
        observedPID = nil
        observedWindow = nil
        needsSampling = false
    }

    private func removeAXObserver() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .commonModes)
        }
        axObserver = nil
    }
}
