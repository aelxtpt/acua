import Foundation

/// One registration for the permission transition's unique overlay source.
@MainActor final class SystemSettingsSpringDriverBinding {
    let animation: SystemSettingsSpringAnimation
    let driver: SystemSettingsDisplayLinkDriver
    private(set) var isRegistered=false
    private var started=false
    init(animation: SystemSettingsSpringAnimation,driver: SystemSettingsDisplayLinkDriver) {
        self.animation=animation;self.driver=driver
    }
    func start() {
        guard !started else { return };started=true;isRegistered=true
        // The registration keeps the animation alive independently of its UI
        // owner until completion or explicit cancellation removes the row.
        driver.frameCallback={ [self] frame in
            guard isRegistered else { return }
            animation.performTick(frame)
            if animation.state == .finished { removeRegistration() }
        }
        driver.start()
    }
    private func removeRegistration() {
        guard isRegistered else { return }
        isRegistered=false;driver.frameCallback=nil;driver.stop()
    }
    func cancel() {
        animation.eventHandler=nil
        removeRegistration()
        animation.stop(immediately:true)
    }
}
