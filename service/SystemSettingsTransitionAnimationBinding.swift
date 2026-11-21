import Foundation

/// Connects the transition controller's lifetime to the production spring
/// and its unique native display-link registration.
@MainActor enum SystemSettingsTransitionAnimationBinding<Artwork: Sendable> {
    typealias Controller = SettingsTransitionController<Artwork>

    static func make(configuration: Controller.Spring, driver: SystemSettingsDisplayLinkDriver) -> Controller.Animation {
        let spring = SystemSettingsSpringAnimation(initialValue: configuration.initialValue,
                                                   targetValue: configuration.targetValue,
                                                   period: configuration.period,
                                                   dampingFraction: configuration.dampingFraction,
                                                   idleVelocityThreshold: configuration.idleVelocityThreshold)
        let registration = SystemSettingsSpringDriverBinding(animation: spring, driver: driver)
        return .init(setHandler: { handler in
            guard let handler else { spring.eventHandler = nil; return }
            spring.eventHandler = { event in
                switch event {
                case .valueChanged(_, let value): handler(.value(value))
                case .finished: handler(.finished)
                case .targetChanged: handler(.other)
                }
            }
        }, start: { registration.start() }, stopImmediately: { registration.cancel() })
    }
}
