import AppKit

final class AXVoiceOverPreference: @unchecked Sendable {
    static let shared: AXVoiceOverPreference? = {
        guard let preferences = UserDefaults(suiteName: "com.apple.universalaccess") else { return nil }
        let key = "voiceOverOnOffKey"
        return AXVoiceOverPreference(read: { preferences.bool(forKey: key) },
            write: { preferences.set($0, forKey: key) },
            notify: {
                DistributedNotificationCenter.default().post(
                    name: .init("com.apple.universalaccess.VoiceOverSettingsDidChange"), object: nil)
            }, voiceOverRunning: {
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver")
                    .contains { !$0.isTerminated }
            })
    }()

    enum Mode: Equatable { case persistent, pulse }

    static func mode(bundle: String, fullContext: Bool) -> Mode? {
        if bundle == "com.microsoft.Excel" || bundle == "com.apple.Music" { return .persistent }
        if fullContext && (bundle == "company.thebrowser.Browser" || bundle == "company.thebrowser.dia") {
            return .pulse
        }
        return nil
    }

    private let lock = NSLock()
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private let notify: () -> Void
    private let voiceOverRunning: () -> Bool
    private struct User {
        let mode: Mode
        var count: Int
    }
    private var users: [String: User] = [:]
    private var pulseTask: Task<Void, Never>?
    private var pulseID: UUID?
    private var stopped = false

    init(read: @escaping () -> Bool, write: @escaping (Bool) -> Void, notify: @escaping () -> Void,
         voiceOverRunning: @escaping () -> Bool) {
        self.read = read
        self.write = write
        self.notify = notify
        self.voiceOverRunning = voiceOverRunning
    }

    func acquire(process: String, mode: Mode) -> (lease: AXAccessibilityTracker.Lease, changed: Bool)? {
        lock.withLock {
            guard !stopped else { return nil }
            var changed = false
            if users[process] == nil {
                let enabled = read()
                if users.isEmpty && enabled { return nil }
                if !enabled {
                    guard !voiceOverRunning() else { return nil }
                    write(true)
                    guard read() else { return nil }
                    notify()
                    changed = true
                    if mode == .pulse { schedulePulse() }
                }
            }
            users[process, default: User(mode: mode, count: 0)].count += 1
            return (AXAccessibilityTracker.Lease { self.release(process) }, changed)
        }
    }

    func shutdown() {
        lock.withLock {
            stopped = true
            guard !users.isEmpty else { return }
            users.removeAll()
            restore()
        }
    }

    private func schedulePulse() {
        pulseTask?.cancel()
        let id = UUID()
        pulseID = id
        pulseTask = Task.detached { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { return }
            self?.finishPulse(id)
        }
    }

    private func finishPulse(_ id: UUID) {
        lock.withLock {
            guard pulseID == id else { return }
            pulseID = nil
            pulseTask = nil
            // A pulse resets the preference without posting a notification.
            if !users.values.contains(where: { $0.mode == .persistent }), !voiceOverRunning() {
                write(false)
            }
        }
    }

    private func release(_ process: String) {
        lock.withLock {
            guard let user = users[process] else { return }
            if user.count > 1 {
                users[process]?.count = user.count - 1
                return
            }
            users.removeValue(forKey: process)
            guard users.isEmpty else { return }
            restore()
        }
    }

    private func restore() {
        pulseTask?.cancel()
        pulseTask = nil
        pulseID = nil
        guard !voiceOverRunning() else { return }
        write(false)
        notify()
    }
}
