import AppKit
import Foundation

enum ControllerNativeUserInput {
    static let eventTypes: [UInt32] = [10, 1, 3, 25, 22]
    static let tapConfiguration = ControllerFocusTapConfiguration(location: .annotatedSession,
        types: eventTypes, tail: true, listenOnly: true)

    static func events() -> AsyncStream<ControllerUserInputObservation> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            let tap = ControllerFocusNativeTap(tapConfiguration)
            // Native getters convert to these exact widths and deliberately
            // keep their integer range preconditions.
            tap.start { _, wrapper in
                // Retain a stable native packet; defer all field conversions
                // until the consumer has passed its cancellation check.
                guard let copy = wrapper.event.copy() else { return wrapper }
                let retained = ControllerFocusNativeEvent(event: copy)
                continuation.yield(.init(read: {
                    let event = retained.event
                    return .init(sourcePID: Int32(event.getIntegerValueField(.eventSourceUnixProcessID)),
                        targetPID: Int32(event.getIntegerValueField(.eventTargetUnixProcessID)),
                        windowID: UInt32(event.getIntegerValueField(CGEventField(rawValue: 51)!)))
                }))
                return wrapper
            }
            continuation.onTermination = { @Sendable _ in tap.stop() }
        }
    }
    static var targetResolver: ControllerUserInputTargetResolver<ControllerOwnerRunningApplication> {
        .init(windowOwner: { ControllerWindowDescription.lookup($0)?.ownerPID },
            application: { NSRunningApplication(processIdentifier: $0).map { .init(application: $0) } },
            bundleURL: { $0.application.bundleURL }, bundleIdentifier: { $0.application.bundleIdentifier })
    }
    static var environment: ControllerUserInputMonitor.Environment {
        let resolver = targetResolver
        return .init(ignoredSourcePID: getpid(), events: { events() }, resolveTarget: { resolver.resolve($0) })
    }
}
