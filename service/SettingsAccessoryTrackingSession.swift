import Foundation

/// The production composition of the window tracker and presentation owner.
/// Providers supply actual native effects; the state machines remain unchanged.
@MainActor final class SettingsAccessoryTrackingSession<Application: Sendable, Artwork: Sendable> {
    typealias Tracker=SystemSettingsWindowTracker<Application>
    typealias Presentation=SettingsAccessoryPresentation<Artwork>
    let tracker: Tracker
    let presentation: Presentation

    init(trackerEnvironment: Tracker.Environment, presentationEnvironment: (Tracker) -> Presentation.Environment) {
        let tracker=Tracker(environment:trackerEnvironment)
        self.tracker=tracker
        presentation=Presentation(environment:presentationEnvironment(tracker))
    }

    func prepare(source: Presentation.Capture?, transitionsEnabled: Bool) {
        presentation.prepare(source:source,transitionsEnabled:transitionsEnabled)
    }

    func start(application: Application, isScreenRecordingPermission: Bool) async throws {
        try await tracker.start(application:application,isScreenRecordingPermission:isScreenRecordingPermission,observer:presentation)
    }

    func clear() {
        tracker.clearTracking()
        presentation.cleanup()
    }
}
