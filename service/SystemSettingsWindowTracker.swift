import Foundation
import CoreGraphics

/// Releasing the owning observation releases its native registration. Scroll
/// registrations additionally have an explicit remove/stop sequence.
final class SystemSettingsWindowObservation: @unchecked Sendable {
    private let release: @Sendable () -> Void
    init(release: @escaping @Sendable () -> Void) { self.release=release }
    deinit { release() }
}
struct SystemSettingsScrollObservation: Sendable {
    let lifetime: SystemSettingsWindowObservation
    let removeNotifications: @MainActor @Sendable () -> Void
    let stopMonitoring: @MainActor @Sendable () -> Void
}
struct SystemSettingsScrollObservationRequest: Sendable {
    let notifications=["AXValueChanged","AXRowCountChanged"]
    let ignoredErrors=[Int32]()
    let qualityOfService=QualityOfService.userInitiated
}
@MainActor protocol SystemSettingsWindowTrackingObserver: AnyObject {
    func settingsWindowChanged(_ window: SystemSettingsWindowRecord?, applicationIsActive: Bool)
}

/// State/lifetime and delivered callback behavior. Actual native
/// window-server and AX observer registrations remain explicit providers.
@MainActor final class SystemSettingsWindowTracker<Application: Sendable> {
    struct Environment: Sendable {
        let waitForWindow: @MainActor @Sendable (Application) async throws -> SystemSettingsWindowRecord
        let onscreenWindows: @MainActor @Sendable (Application) -> [SystemSettingsWindowRecord]
        let observeApplication: @MainActor @Sendable (Application, @escaping @Sendable () -> Void,
            @escaping @Sendable (Bool) -> Void) -> SystemSettingsWindowObservation
        let observeWindow: @MainActor @Sendable (SystemSettingsWindowRecord, [UInt8],
            @escaping @Sendable (SystemSettingsWindowRecord, UInt8) -> Void) -> SystemSettingsWindowObservation
        let observeScroll: @MainActor @Sendable (Application, SystemSettingsScrollObservationRequest,
            @escaping @Sendable (String) -> Void) throws -> SystemSettingsScrollObservation
        var scheduleScroll: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { operation in
            Task { @MainActor in operation() }
        }
    }
    let environment: Environment
    private(set) var observedApplication: Application?
    private(set) var hasObservedWindow=false
    private(set) var applicationIsActive=false
    private(set) var lastWindow: SystemSettingsWindowRecord?
    var didLaunch=false
    private(set) var cachedAudioRecordingHeadingBounds: CGRect?
    weak var observer: (any SystemSettingsWindowTrackingObserver)?
    private var applicationObservation: SystemSettingsWindowObservation?
    private var windowObservation: SystemSettingsWindowObservation?
    private var scrollObservation: SystemSettingsScrollObservation?
    init(environment: Environment) { self.environment=environment }

    func start(application: Application, isScreenRecordingPermission: Bool,
               observer: any SystemSettingsWindowTrackingObserver) async throws {
        clearTracking()
        observedApplication=application;self.observer=observer
        let window=try await environment.waitForWindow(application)
        updateApplicationIsActive(true)
        updateWindow(window)
        applicationObservation=environment.observeApplication(application,{ [weak self] in
            Self.deliver { [weak self] in self?.applicationTerminated() }
        },{ [weak self] active in Self.deliver { [weak self] in self?.updateApplicationIsActive(active) } })
        windowObservation=environment.observeWindow(window,[6,7,3,4,16],{ [weak self] window,event in
            Self.deliver { [weak self] in self?.windowEvent(window,event:event) }
        })
        if isScreenRecordingPermission {
            scrollObservation=try? environment.observeScroll(application,.init(),{ [weak self] role in self?.scrollEvent(role:role) })
        }
    }
    func clearTracking() {
        observedApplication=nil;hasObservedWindow=false
        applicationObservation=nil;windowObservation=nil;observer=nil
        if let scroll=scrollObservation {
            scroll.removeNotifications();scroll.stopMonitoring();scrollObservation=nil
        }
        // Intentionally retains activity, lastWindow, launch and heading.
    }
    func updateWindow(_ window: SystemSettingsWindowRecord?) {
        if window != nil { hasObservedWindow=true }
        lastWindow=window;notify()
    }
    func updateApplicationIsActive(_ active: Bool) {
        applicationIsActive=active
        if !active {
            lastWindow=observedApplication.flatMap { environment.onscreenWindows($0).first { $0.qualifiesAsMainSettingsWindow } }
        }
        notify()
    }
    func windowEvent(_ window: SystemSettingsWindowRecord, event: UInt8) {
        // The ordinal mask0x10018 clears events3,4,16. These are not raw
        // WindowServer notification numbers (803,804,816 respectively).
        updateWindow(Self.clearsWindow(event:event) ? nil:window)
    }
    nonisolated static func clearsWindow(event: UInt8) -> Bool { event == 3 || event == 4 || event == 16 }
    func applicationTerminated() {
        observedApplication=nil;applicationObservation=nil;windowObservation=nil
        updateWindow(nil);updateApplicationIsActive(false)
        // Unlike clearTracking, termination keeps delegate, scroll and latch.
    }
    nonisolated func scrollEvent(role: String) {
        guard role == "AXScrollBar" else { return }
        environment.scheduleScroll { [self] in cachedAudioRecordingHeadingBounds=nil;notify() }
    }
    func audioRecordingHeadingBounds(resolve: () -> CGRect?) -> CGRect? {
        if let cachedAudioRecordingHeadingBounds { return cachedAudioRecordingHeadingBounds }
        let result=resolve()
        if let result { cachedAudioRecordingHeadingBounds=result }
        return result
    }
    private func notify() { observer?.settingsWindowChanged(lastWindow,applicationIsActive:applicationIsActive) }
    nonisolated private static func deliver(_ operation: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated { operation() } }
        else { DispatchQueue.main.async(execute:operation) }
    }
}
