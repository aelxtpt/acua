import Foundation

/// Uses the same CGWindow.Observer as controller window ordering. Preserve its shared registry, raw request and teardown behavior.
enum SettingsWindowNativeProducer {
    static func native(windowIDs: [UInt32], events: [UInt8],
                       handler: @escaping SettingsWindowServerObservation.Handler) -> SystemSettingsWindowObservation {
        guard let producer = ControllerWindowNativeProducer.native() else {
            preconditionFailure("Native window producer is unavailable")
        }
        return observe(windowIDs: windowIDs, events: events, producer: producer, handler: handler)
    }

    static func observe(windowIDs: [UInt32], events: [UInt8], producer: ControllerWindowNativeProducer,
                        handler: @escaping SettingsWindowServerObservation.Handler) -> SystemSettingsWindowObservation {
        let nativeEvents = events.map { ordinal in
            ControllerWindowServerEvent(rawValue: SettingsWindowServerObservation.rawValue(ordinal))!
        }
        let registration = producer.observe(windowIDs: windowIDs, events: nativeEvents) { description, event in
            // Forward a live description without an additional ID filter.
            let record = SystemSettingsWindowRecord(identifier: description.id, ownerPID: description.ownerPID,
                frame: description.bounds, level: description.level, name: description.name,
                ownerName: description.ownerName, isOnscreen: description.isOnscreen)
            handler(record, SettingsWindowServerObservation.ordinal(event.rawValue)!)
        }
        return .init { withExtendedLifetime(registration) {} }
    }
}
