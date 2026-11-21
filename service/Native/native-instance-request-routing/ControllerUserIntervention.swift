import Foundation

struct ControllerUserIntervention: Equatable, Sendable {
    var requiresRequery: Bool
    var debounceDeadline: Date?

    // Integer conversion deliberately keeps the
    // precondition for a non-finite/out-of-range Date, including a past date.
    func secondsRemaining(at now: Date) -> Int {
        guard let debounceDeadline else { return 0 }
        return max(0, Int(ceil(debounceDeadline.timeIntervalSince(now))))
    }
    func isDebouncing(at now: Date) -> Bool {
        guard let debounceDeadline else { return false }
        return Int(ceil(debounceDeadline.timeIntervalSince(now))) > 0
    }
}

enum ControllerInterventionReason: Equatable, Sendable {
    case stoppedByUser
    case userInterrupted(ControllerUserIntervention)
}

enum ControllerInstanceResolutionError: Error, Equatable {
    case noInstance(String)
    case stoppedByUser(String)
}
