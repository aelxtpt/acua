import AppKit

extension SystemSettingsWindowTracker.Environment where Application == SystemSettingsNativeApplication {
    /// CG window snapshots, the5s/100ms first-window wait, and KVO are bound
    /// here. Window-server/AX registrations must be supplied by their owners.
    @MainActor static func native(
        observeWindow: @escaping @MainActor @Sendable (SystemSettingsWindowRecord, [UInt8],
            @escaping @Sendable (SystemSettingsWindowRecord,UInt8) -> Void) -> SystemSettingsWindowObservation,
        observeScroll: @escaping @MainActor @Sendable (Application, SystemSettingsScrollObservationRequest,
            @escaping @Sendable (String) -> Void) throws -> SystemSettingsScrollObservation) -> Self {
        let windows: @MainActor @Sendable (Application) -> [SystemSettingsWindowRecord] = {
            SystemSettingsWindowRecord.nativeWindows(ownerPID:$0.application.processIdentifier,onscreenOnly:true)
        }
        return .init(waitForWindow:{ application in
            let started=Date.now
            while Date.now.timeIntervalSince(started) <= 5 {
                if let window=windows(application).first(where:{ $0.qualifiesAsMainSettingsWindow }) { return window }
                let clock=ContinuousClock()
                try await clock.sleep(until:clock.now.advanced(by:.milliseconds(100)),tolerance:nil)
            }
            throw SystemSettingsPollError.timeoutReached
        },onscreenWindows:windows,observeApplication:{ application,terminated,active in
            let native=application.application
            // KVO handlers use no initial/new options and termination
            // invokes its handler for every delivery, without checking the value.
            let termination=native.observe(\.isTerminated,options:[]) { _,_ in terminated() }
            let activity=native.observe(\.isActive,options:[]) { app,_ in active(app.isActive) }
            let lifetime=NativeSettingsApplicationObservations(native,termination,activity)
            return SystemSettingsWindowObservation { _ = lifetime }
        },observeWindow:observeWindow,observeScroll:observeScroll)
    }
}
private final class NativeSettingsApplicationObservations: @unchecked Sendable {
    let application: NSRunningApplication
    let termination: NSKeyValueObservation
    let activity: NSKeyValueObservation
    init(_ application: NSRunningApplication,_ termination: NSKeyValueObservation,_ activity: NSKeyValueObservation) {
        self.application=application;self.termination=termination;self.activity=activity
    }
    deinit {
        // Swift may destroy the application property before the observation
        // properties. Remove KVO while the observed application is still alive.
        termination.invalidate()
        activity.invalidate()
        withExtendedLifetime(application) {}
    }
}

