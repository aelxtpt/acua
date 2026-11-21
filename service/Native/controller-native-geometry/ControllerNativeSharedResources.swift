import Foundation

extension ControllerNativeResources {
    /// The production composition uses the existing tree TaskLocal and cache,
    /// with the same global hosted lookup for identity, reads and writes.
    static func shared(lookup: @escaping ControllerNativeElementIO.Lookup,
                       windowServer: ControllerNativeWindowServer,
                       actions: ControllerFocusSynthesizedActionState = .shared,
                       log: @escaping @Sendable (String, any Error) -> Void) -> ControllerNativeResources {
        .init(context: .shared(lookup: { key in
            lookup(key).map { .init(actualPID: $0.actualPID, windowID: $0.windowID, bundleIdentifier: $0.bundleIdentifier) }
        }, log: log), lookup: lookup, windowServer: windowServer, actions: actions)
    }
}
