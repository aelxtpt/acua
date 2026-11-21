import Foundation

enum TimelineSettingsTelemetry {
    static func parameters(type:TimelineObservationSettingsUpdateType,settings:TimelineSettings)->[String:Any] {
        // Settings updates leave agent metadata and the private-browsing
        // flag absent. Do not fabricate fields
        // from a request's logging context or from rule counts.
        ["@type":"acua.telemetry.v1.TimelineObservationSettingsUpdated",
         "updateType":type.telemetryValue,
         "defaultApplicationBehavior":settings.observation.defaultApplicationBehavior.rawValue,
         "defaultUrlBehavior":settings.observation.defaultURLBehavior.rawValue]
    }
}
