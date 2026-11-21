import AppKit
import ApplicationServices

@MainActor
final class RemoteHostedPIPWindowGeometryObserver {
    private struct WindowState: Equatable {
        let frame: CGRect
        let owner: Int32?
        let onScreen: Bool
    }

    private let onChange: () -> Void
    private let windowID: CGWindowID
    private var windows: Set<CGWindowID>
    private var lastSnapshot: [CGWindowID: WindowState] = [:]
    private var accessibility: AXObserver?
    private var screens: NSObjectProtocol?
    private var sampler: Task<Void, Never>?
    private var pending: Task<Void, Never>?
    private var windowServer: RemoteHostedPIPWindowServerObserver?
    private var stopped = false

    init(windowID: CGWindowID, associatedWindowIDs: Set<CGWindowID>, pid: Int32?, onChange: @escaping () -> Void) {
        self.onChange = onChange
        self.windowID = windowID
        windows = associatedWindowIDs.union([windowID])
        lastSnapshot = snapshot()
        installWindowServer()
        if let pid { installAccessibility(windowID: windowID, pid: pid) }
        screens = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedule() }
        }
        // Keep a bounded fallback for notifications the system does not deliver.
        sampler = Task { [weak self] in
            while (try? await Task.sleep(for: .milliseconds(500))) != nil {
                guard let self, !self.stopped else { return }
                guard self.pending == nil else { continue }
                let snapshot = self.snapshot()
                if snapshot != self.lastSnapshot {
                    self.lastSnapshot = snapshot
                    self.schedule()
                }
            }
        }
    }

    func updateWindows(windowID: CGWindowID, associatedWindowIDs: Set<CGWindowID>) {
        let updated = associatedWindowIDs.union([windowID])
        guard windows != updated, !stopped else { return }
        windows = updated
        lastSnapshot = snapshot()
        installWindowServer()
    }

    func captureInterrupted() { schedule() }

    func stop() {
        stopped = true
        windowServer = nil
        sampler?.cancel()
        pending?.cancel()
        sampler = nil
        pending = nil
        if let screens { NotificationCenter.default.removeObserver(screens) }
        if let accessibility { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(accessibility), .commonModes) }
        screens = nil
        accessibility = nil
    }

    deinit {
        sampler?.cancel()
        pending?.cancel()
        if let screens { NotificationCenter.default.removeObserver(screens) }
        if let accessibility { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(accessibility), .commonModes) }
    }

    private func installWindowServer() {
        windowServer = RemoteHostedPIPWindowServerObserver(windowIDs: windows) { [weak self] id, event in
            Task { @MainActor in
                guard let self, self.windows.contains(id), !self.stopped else { return }
                self.schedule(delay: event == .terminated && id == self.windowID ? .zero : .milliseconds(240))
            }
        }
    }

    private func schedule(delay: Duration = .milliseconds(240)) {
        guard !stopped else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            guard (try? await Task.sleep(for: delay)) != nil, let self else { return }
            self.pending = nil
            self.lastSnapshot = self.snapshot()
            self.onChange()
        }
    }

    private func snapshot() -> [CGWindowID: WindowState] {
        var state: [CGWindowID: WindowState] = [:]
        for id in windows {
            guard let info = WindowDescription.lookup(id),
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            state[id] = WindowState(frame: frame, owner: (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                                    onScreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false)
        }
        return state
    }

    private func installAccessibility(windowID: CGWindowID, pid: Int32) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let callback: AXObserverCallback = { _, _, _, context in
            guard let context else { return }
            let observer = Unmanaged<RemoteHostedPIPWindowGeometryObserver>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { observer.schedule() }
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        for event in [kAXWindowMovedNotification, kAXWindowResizedNotification, kAXFocusedWindowChangedNotification,
                      kAXMainWindowChangedNotification, kAXWindowCreatedNotification, kAXSheetCreatedNotification] {
            AXObserverAddNotification(observer, app, event as CFString, context)
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement],
           let window = windows.first(where: { (try? AccessibilityWindowSPI.windowID($0)) == windowID }) {
            for event in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification] {
                AXObserverAddNotification(observer, window, event as CFString, context)
            }
        }
        accessibility = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }
}
