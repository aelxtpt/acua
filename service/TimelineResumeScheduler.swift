import Foundation

// Both successful and throwing
// sleep continuations check cancellation before inspecting the weak owner.
// The lifecycle callback separately requires a live, paused owner.
@MainActor enum TimelineResumeScheduler {
    static func schedule(at date:Date,action:@escaping @MainActor ()->Void)->Task<Void,Never> {
        Task{@MainActor in
            let delay=max(0,date.timeIntervalSinceNow)
            try?await ContinuousClock().sleep(for:.seconds(delay))
            guard !Task.isCancelled else{return}
            action()
        }
    }
}
