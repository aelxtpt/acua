import Foundation

private final class App {
    let id: Int
    var current = false
    var terminated = false
    init(_ id: Int, current: Bool = false) { self.id = id; self.current = current }
}

@main enum EventStreamFrontmostTests {
    static func main() {
        var count = 0, fallbacks = 0
        let service = App(1, current: true), first = App(2), next = App(3)
        var replacement: App? = first
        let state = EventStreamFrontmostTrackerState<App>(isCurrent: { $0.current },
            isTerminated: { $0.terminated }, equal: { $0.id == $1.id },
            fallback: { fallbacks += 1; return replacement })
        func check(_ label: String, _ value: @autoclosure () -> Bool) {
            guard value() else { fatalError("FAIL: \(label)") }
            count += 1; print("PASS: \(label)")
        }
        check("uninitialized tracker does not call fallback", state.current() == nil && fallbacks == 0)
        check("initial self activation resolves fallback application", state.update(service) && state.current() === first && fallbacks == 1)
        check("self activation keeps previous foreign application", !state.update(service) && state.current() === first && fallbacks == 1)
        check("foreign activation replaces tracked application", state.update(next) && state.current() === next)
        check("equal native identity is not a duplicate change", !state.update(App(3)) && state.current() === next)
        first.terminated = true
        check("unrelated process termination does not affect live tracked app", state.current() === next)
        next.terminated = true; replacement = first
        check("terminated tracked app resolves current fallback", state.current() === first && fallbacks == 2)
        replacement = App(4)
        check("read fallback is not written back into saved state", state.current() === replacement && fallbacks == 3)
        check("self update keeps saved nonself identity even when terminated", !state.update(service) && fallbacks == 3)
        replacement = nil
        check("unavailable fallback after termination returns nil", state.current() == nil)
        let fresh = App(5)
        check("next activation recovers after missing fallback", state.update(fresh) && state.current() === fresh)
        fresh.current = true; replacement = first
        check("saved self identity triggers fallback on next self activation", state.update(service) && state.current() === first)
        let unfiltered = EventStreamFrontmostTrackerState<App>(excludeCurrent: false,
            isCurrent: { $0.current }, isTerminated: { $0.terminated }, equal: { $0.id == $1.id }, fallback: { service })
        check("unfiltered tracker accepts current application", unfiltered.update(service) && unfiltered.current() === service)
        let empty = EventStreamFrontmostTrackerState<App>(isCurrent: { $0.current },
            isTerminated: { $0.terminated }, equal: { $0.id == $1.id }, fallback: { nil })
        check("self update without prior app or fallback preserves empty state", !empty.update(service) && empty.current() == nil)
        print("EVENT STREAM FRONTMOST TRACKER: \(count) checks passed")
    }
}
