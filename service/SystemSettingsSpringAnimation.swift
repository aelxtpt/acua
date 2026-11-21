import Foundation

struct SystemSettingsAnimationFrame: Sendable,Equatable {
    let timestamp: Double
    let duration: Double
    let targetTimestamp: Double
}

/// Scalar spring animation behavior.
/// Driver/coordinator registration and per-screen renderer have separate owners.
@MainActor final class SystemSettingsSpringAnimation {
    enum State: UInt8 { case initial=0,retargeted=1,running=2,finished=3 }
    enum Event { case valueChanged(oldValue: Double,newValue: Double),finished(Double),targetChanged(fromValue: Double,toValue: Double) }
    var eventHandler: (@MainActor (Event) -> Void)?
    var stateDidChange: (@MainActor (State) -> Void)?
    private(set) var state: State = .initial
    private(set) var startTime: Double?
    private(set) var simulation: SystemSettingsScalarSpring
    var value: Double { simulation.value }
    var targetValue: Double {
        get { simulation.target }
        set {
            let previous=simulation.target;simulation.target=newValue
            if state == .running && previous != simulation.target {
                setState(.retargeted)
                eventHandler?(.targetChanged(fromValue:previous,toValue:simulation.target))
            }
        }
    }
    var isLogicallyComplete: Bool {
        if let startTime { return simulation.time-startTime >= simulation.configuration.period }
        return state == .finished
    }
    init(initialValue: Double=0,targetValue: Double=1,period: Double=0.72,dampingFraction: Double=1,idleVelocityThreshold: Double?=nil) {
        simulation = .init(configuration:.init(period:period,dampingFraction:dampingFraction,tolerance:idleVelocityThreshold ?? 0.06),value:initialValue,target:targetValue)
    }
    private func setState(_ state: State) {
        let previous=self.state;self.state=state
        if previous != state { stateDidChange?(state) }
    }
    private func setValue(_ value: Double) {
        let old=simulation.value;simulation.value=value
        if let handler=eventHandler,old != simulation.value { handler(.valueChanged(oldValue:old,newValue:simulation.value)) }
    }
    func performTick(_ frame: SystemSettingsAnimationFrame) {
        if state != .running { simulation.setTime(frame.timestamp);startTime=frame.timestamp }
        setState(.running)
        let old=simulation.value
        // Each tick evolves a copy of the current value. A final
        // step is discarded before finish snaps the stored value to target.
        simulation.advance(to:frame.targetTimestamp)
        let complete=simulation.isComplete,newValue=simulation.value
        simulation.value=old
        if complete { finish() }
        else { setValue(newValue) }
    }
    private func finish() {
        setValue(simulation.target)
        if state != .finished {
            eventHandler?(.finished(simulation.target))
            setState(.finished)
        }
    }
    func stop(immediately: Bool) {
        if immediately { setState(.finished);eventHandler?(.finished(simulation.value)) }
        else { targetValue=simulation.value }
    }
    func reset() {
        simulation.reset();startTime=nil;setState(.initial)
    }
}
