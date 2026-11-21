import Foundation

enum CursorInteractionTiming {
    case closeEnough, finished

    // Keep both comparisons;
    // progress alone does not bound the remaining distance on a long path.
    static func permitsEarlyInteraction(progress: Double, distance: Double, alreadySatisfied: Bool) -> Bool {
        progress >= 0.995 && distance <= 3.157 && !alreadySatisfied
    }
}

/// Main-thread completion ownership for the approved cursor's animations.
/// Clear/replace the slot before invoking a callback so reentrant updates own
/// their new token; an old timer can never finish a newer movement.
final class CursorMotionCompletion {
    private struct Entry { let token: UUID; let timing: CursorInteractionTiming; var completion: ((Bool) -> Void)? }
    private var current: Entry?
    var currentToken: UUID? { current?.token }

    func begin(_ completion: ((Bool) -> Void)?, timing: CursorInteractionTiming = .finished) -> UUID {
        let previous = current
        let token = UUID()
        current = Entry(token: token, timing: timing, completion: completion)
        previous?.completion?(false)
        return token
    }

    func isCurrent(_ token: UUID) -> Bool { current?.token == token }

    func advance(_ token: UUID, progress: Double, distance: Double) {
        guard let entry = current, entry.token == token, entry.timing == .closeEnough,
              let completion = entry.completion,
              CursorInteractionTiming.permitsEarlyInteraction(progress: progress, distance: distance, alreadySatisfied: false) else { return }
        // Release the interaction once while retaining ownership of the
        // still-running visual movement. Reentrant callbacks may replace it.
        current?.completion = nil
        completion(true)
    }

    func finish(_ token: UUID, completed: Bool) {
        guard current?.token == token else { return }
        let entry = current
        current = nil
        entry?.completion?(completed)
    }
}
