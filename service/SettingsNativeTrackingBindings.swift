import AppKit
import ApplicationServices

extension SystemSettingsWindowTracker.Environment where Application == SystemSettingsNativeApplication {
    @MainActor static func fullyNative() -> Self {
        .native(observeWindow:{ window,events,handler in
            let registration=SettingsWindowServerObservation(windowIDs:[window.identifier],events:events,api:.native) { record,event in
                // Native requests share a connection-wide union. Keep this
                // tracker scoped to its own window while the generic observer
                // keeps the unfiltered live-description contract.
                guard record.identifier == window.identifier else { return }
                handler(record,event)
            }
            return registration.trackerLifetime()
        },observeScroll:{ application,request,handler in
            let target=SettingsNativeAXElement(element:AXUIElementCreateApplication(application.application.processIdentifier))
            let registration=try SettingsScrollRegistration<SettingsNativeAXObserver,SettingsNativeAXElement>(
                pid:application.application.processIdentifier,element:target,request:request,environment:.native,handler:handler)
            return registration.trackerObservation(request:request)
        })
    }
}
extension SystemSettingsWindowTracker where Application == SystemSettingsNativeApplication {
    func audioRecordingHeadingBounds(for window: SystemSettingsWindowRecord) -> CGRect? {
        audioRecordingHeadingBounds {
            let snapshots=EventStreamNativeSnapshots()
            return SettingsAudioHeading<EventStreamAXNode>.ax(application:{ snapshots.node(AXUIElementCreateApplication($0)) },
                isMacOS26OrLater:{ if #available(macOS 26,*) { return true };return false }).resolve(ownerPID:window.ownerPID)
        }
    }
}
