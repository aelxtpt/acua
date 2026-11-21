import Foundation

/// Scalar velocity-Verlet spring simulation. The display
/// driver and InterpolatableAnimation event lifecycle are separate owners.
struct SystemSettingsScalarSpring: Sendable {
    struct Configuration: Sendable {
        let period: Double
        let stiffness: Double
        let damping: Double
        let timeStep: Double=1.0/240
        let tolerance: Double
        init(period: Double=0.72,dampingFraction: Double=1,tolerance: Double=0.06) {
            self.period=period
            let frequency=period > 0 ? 2*Double.pi/period:Double.infinity
            stiffness=min(frequency*frequency,28800)
            damping=(stiffness.squareRoot()*2)*dampingFraction
            self.tolerance=tolerance
        }
    }
    var configuration: Configuration
    var value: Double
    var target: Double
    private(set) var time: Double
    private(set) var velocity: Double
    private(set) var acceleration: Double
    init(configuration: Configuration = .init(),value: Double=0,target: Double=1,time: Double=0,velocity: Double=0,acceleration: Double=0) {
        self.configuration=configuration;self.value=value;self.target=target;self.time=time;self.velocity=velocity;self.acceleration=acceleration
    }
    /// Resets velocity/acceleration only, preserving time and caller value.
    mutating func reset() { velocity=0;acceleration=0 }
    /// Beginning a run/retarget rebases time without discarding motion.
    mutating func setTime(_ timestamp: Double) { time=timestamp }
    /// Stepping does not advance time; `advance` owns time accumulation.
    mutating func step() {
        let halfStep=configuration.timeStep*0.5
        let halfVelocity=velocity+acceleration*halfStep
        value=value+halfVelocity*configuration.timeStep
        acceleration=(-configuration.damping)*halfVelocity+(target-value)*configuration.stiffness
        velocity=halfVelocity+acceleration*halfStep
    }
    mutating func advance(to timestamp: Double) {
        if timestamp-time > 1 { time=timestamp-1.0/60 }
        while time < timestamp {
            step()
            time=configuration.timeStep+time
        }
    }
    /// Intentionally uses ordered `>` tests, including its zero-target
    /// and non-finite behavior. Do not replace this with an epsilon distance.
    var isComplete: Bool {
        let speed=abs(velocity),force=abs(acceleration)
        if max(speed*speed,force*force) > configuration.tolerance*configuration.tolerance { return false }
        let targetTolerance=target*0.01
        let toleranceSquared=abs(targetTolerance)*abs(targetTolerance)
        let difference=abs(target-value)
        if toleranceSquared > 0 && difference*difference > toleranceSquared { return false }
        return true
    }
}
