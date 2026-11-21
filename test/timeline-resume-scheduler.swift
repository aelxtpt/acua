import Foundation

@main private enum Main {
    @MainActor static func main()async throws {
        var fired=0
        let expired=TimelineResumeScheduler.schedule(at:Date(timeIntervalSinceNow:-60)){precondition(Thread.isMainThread);fired+=1}
        await expired.value
        precondition(fired==1);print("PASS: expired deadline executes once on main actor")
        let immediateCancellation=TimelineResumeScheduler.schedule(at:Date(timeIntervalSinceNow:60)){fired+=1}
        immediateCancellation.cancel();await immediateCancellation.value
        precondition(fired==1);print("PASS: cancellation before scheduling prevents callback")
        let sleeping=TimelineResumeScheduler.schedule(at:Date(timeIntervalSinceNow:60)){fired+=1}
        try await ContinuousClock().sleep(for:.milliseconds(5))
        sleeping.cancel();await sleeping.value
        precondition(fired==1);print("PASS: cancellation interrupts sleep and prevents callback")
        let deadline=Date(timeIntervalSinceNow:0.015)
        let due=TimelineResumeScheduler.schedule(at:deadline){precondition(Thread.isMainThread);precondition(Date()>=deadline);fired+=1}
        await due.value
        precondition(fired==2);print("PASS: real continuous-clock wait reaches deadline once")
        print("4 local scheduler checks passed")
    }
}
