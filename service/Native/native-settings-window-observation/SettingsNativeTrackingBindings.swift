import AppKit
import ApplicationServices

extension SystemSettingsWindowTracker.Environment where Application == SystemSettingsNativeApplication {
    @MainActor static func fullyNative() -> Self {
        .native(observeWindow:{ window,events,handler in
            SettingsWindowNativeProducer.native(windowIDs:[window.identifier],events:events,handler:handler)
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
