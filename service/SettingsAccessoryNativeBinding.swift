import AppKit

/// Owns the actual C67 request coordinator, C69 native tracker and C70
/// presentation together. Visual content/transition renderer, activation
/// suppression and permission implementations remain their explicit owners.
@MainActor final class SettingsAccessoryNativeBinding<Artwork: Sendable> {
    typealias Presentation=SettingsAccessoryPresentation<Artwork>
    typealias Access=SystemSettingsAccessCoordinator<SystemSettingsNativeApplication,Presentation.Capture>
    private final class Links {
        weak var access: Access?
    }
    let access: Access
    let tracker: SystemSettingsWindowTracker<SystemSettingsNativeApplication>
    let presentation: Presentation
    init(isScreenRecording: @escaping @MainActor @Sendable (Access.PrivacyPermission) -> Bool,
         transitionsEnabled: @escaping @MainActor @Sendable () -> Bool = { true },
         preventActivation: @escaping @MainActor @Sendable (SystemSettingsNativeApplication) async -> Void,
         reenableActivation: @escaping @MainActor @Sendable () async -> Void,
         makeWindow: @escaping (Presentation.Permission,@escaping @MainActor () -> Void,@escaping @MainActor (CGPoint) -> Void) -> Presentation.Window,
         makeTransition: @escaping () -> Presentation.Transition) {
        let links=Links()
        let tracker=SystemSettingsWindowTracker<SystemSettingsNativeApplication>(environment:.fullyNative())
        self.tracker=tracker
        let presentation=Presentation(environment:.init(permission:{
            links.access?.requestingPrivacyPermission.map { .init(identifier:$0.identifier,isScreenRecording:isScreenRecording($0)) }
        },firstScreenHeight:{ NSScreen.screens.first?.frame.height },hasObservedWindow:{ tracker.hasObservedWindow },
        lastWindow:{ tracker.lastWindow },heading:{ tracker.audioRecordingHeadingBounds(for:$0) },
        withoutTransition:{ links.access?.shouldPresentAccessoryWithoutTransition ?? false },
        makeWindow:makeWindow,makeTransition:makeTransition,clearTracking:{ tracker.clearTracking() },
        activateApplication:{ NSApp!.activate() },activateSettings:{ _ = tracker.observedApplication?.application.activate(options:[.activateAllWindows]) },
        transitionStarted:{ links.access?.accessoryTransitionStarted() },reverseCompleted:{ links.access?.accessoryReverseTransitionCompleted() },
        cancelDrag:{ links.access?.cancelPrivacyDrag() },completeDrop:{ links.access?.finishPrivacyDrop() }))
        self.presentation=presentation
        access=Access(environment:.native(windows:{ Access.Environment.nativeWindows($0,onscreenOnly:$1) },
            preventActivation:preventActivation,reenableActivation:reenableActivation,
            presentAccessory:{ application,permission in
                try await tracker.start(application:application,isScreenRecordingPermission:isScreenRecording(permission),observer:presentation)
            },prepareTransition:{ presentation.prepare(source:$0,transitionsEnabled:transitionsEnabled()) },
            clearSettingsTracking:{ tracker.clearTracking() },cleanupPresentation:{ presentation.cleanup() }))
        links.access=access
    }
}
