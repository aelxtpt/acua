import AppKit

// 0x10078F520 / 0x100790468. The tracked application deliberately differs from
// NSWorkspace.frontmostApplication when the service itself becomes foreground.
final class EventStreamFrontmostTrackerState<Application> {
    private let lock = NSLock()
    private var saved: Application?
    private let excludeCurrent: Bool
    private let isCurrent: (Application) -> Bool
    private let isTerminated: (Application) -> Bool
    private let equal: (Application, Application) -> Bool
    private let fallback: () -> Application?

    init(excludeCurrent: Bool = true, isCurrent: @escaping (Application) -> Bool,
         isTerminated: @escaping (Application) -> Bool,
         equal: @escaping (Application, Application) -> Bool,
         fallback: @escaping () -> Application?) {
        self.excludeCurrent = excludeCurrent; self.isCurrent = isCurrent
        self.isTerminated = isTerminated; self.equal = equal; self.fallback = fallback
    }

    @discardableResult func update(_ application: Application) -> Bool {
        updateValue(application) != nil
    }

    func updateValue(_ application:Application)->Application? {
        lock.lock(); defer { lock.unlock() }
        let candidate: Application?
        if excludeCurrent && isCurrent(application) {
            candidate = saved.flatMap { isCurrent($0) ? nil : $0 } ?? fallback()
        } else { candidate = application }
        guard let candidate else { return nil }
        if let saved, equal(saved, candidate) { return nil }
        saved = candidate
        return candidate
    }

    func current() -> Application? {
        lock.lock(); let current = saved; lock.unlock()
        // A never-initialized tracker does not borrow a newly observed app.
        guard let current else { return nil }
        return isTerminated(current) ? fallback() : current
    }
}

final class EventStreamNativeFrontmostTracker {
    static let shared = EventStreamNativeFrontmostTracker()
    private let state: EventStreamFrontmostTrackerState<NSRunningApplication>
    private var observer: NSObjectProtocol?
    private let observers=EventStreamFrontmostObservers<NSRunningApplication>()

    init() {
        let identifier = NSRunningApplication.current.bundleIdentifier
        state = .init(isCurrent: { $0.bundleIdentifier == identifier },
            isTerminated: { $0.isTerminated }, equal: { $0.isEqual($1) },
            fallback: {
                if let current = NSWorkspace.shared.frontmostApplication,
                   let bundle = current.bundleIdentifier, bundle != identifier { return current }
                // 0x1007877C0: CG stacking order, regular visible applications,
                // first occurrence per application, excluding this application.
                let rows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], 0) as? [[String: Any]] ?? []
                let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
                for row in rows {
                    guard let number = row[kCGWindowOwnerPID as String] as? NSNumber,
                          let pid = Int32(exactly: number.int64Value), pid != getpid(),
                          let level = row[kCGWindowLayer as String] as? Int, level < menuLevel,
                          let app = NSRunningApplication(processIdentifier: pid),
                          let bundle = app.bundleIdentifier, bundle != identifier,
                          app.activationPolicy == .regular, !app.isHidden else { continue }
                    return app
                }
                return nil
            })
        if let owner = NSWorkspace.shared.menuBarOwningApplication { state.update(owner) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                guard let self,let updated=self.state.updateValue(app) else {return}
                self.observers.publish(updated)
            }
    }

    var application: NSRunningApplication? { state.current() }
    func addObserver(_ handler:@escaping (NSRunningApplication)->Void)->EventStreamFrontmostObservers<NSRunningApplication>.Token {
        observers.add(handler)
    }
    func removeObserver(_ token:EventStreamFrontmostObservers<NSRunningApplication>.Token) {observers.remove(token)}
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }
}
