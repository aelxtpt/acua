import Foundation

/// System Settings destinations and their URL helper.
enum SystemSettings {
    struct Destination: Codable, Hashable, Sendable {
        let paneID: String
        let anchor: String?
        init(paneID: String, anchor: String? = nil) { self.paneID = paneID; self.anchor = anchor }
        static let notifications = Self(paneID: "com.apple.Notifications-Settings.extension")
        static let privacy = Self(paneID: "com.apple.settings.PrivacySecurity.extension")
        static let privacyFullDiskAccess = privacy("Privacy_AllFiles")
        static let privacyAccessibility = privacy("Privacy_Accessibility")
        static let privacyScreenCapture = privacy("Privacy_ScreenCapture")
        static let privacyLocation = privacy("Privacy_Location")
        static let privacyContacts = privacy("Privacy_Contacts")
        static let privacyCalendar = privacy("Privacy_Calendars")
        static let privacyReminders = privacy("Privacy_Reminders")
        static let privacyAppleEvents = privacy("Privacy_Automation")
        static let privacyCamera = privacy("Privacy_Camera")
        private static func privacy(_ anchor: String) -> Self { .init(paneID: privacy.paneID, anchor: anchor) }
    }
    static func url(for destination: Destination) throws -> URL {
        var string = "x-apple.systempreferences:" + destination.paneID
        // Empty is a present anchor: it still appends the question mark.
        if let anchor = destination.anchor { string += "?" + anchor }
        guard let url = URL(string: string) else { throw URLError(.badURL) }
        return url
    }
}
