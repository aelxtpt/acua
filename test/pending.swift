import Foundation

@main enum PendingTests {
    static func main() throws {
        var count = 0
        func check(_ name: String, _ value: Bool) { precondition(value, name); count += 1; print("PASS \(name)") }
        final class Discards: @unchecked Sendable {
            let lock = NSLock(); var values: [Int] = []
            func add(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
        }
        let discarded = Discards()
        let late = PendingResult<Int>(discard: discarded.add)
        late.abandon(); late.complete(.success(1)); late.abandon()
        check("a callback after expiry releases its resource once", discarded.values == [1])
        let early = PendingResult<Int>(discard: discarded.add)
        early.complete(.success(2)); early.abandon(); early.abandon()
        check("expiry after callback but before consumption releases once", discarded.values == [1, 2])
        let consumed = PendingResult<Int>(discard: discarded.add)
        consumed.complete(.success(3))
        check("completed callback transfers ownership", try consumed.take() == 3)
        consumed.abandon()
        check("consumed resources are not discarded by late cancellation", discarded.values == [1, 2])
        do { _ = try consumed.take(); preconditionFailure("consumed twice") }
        catch is ServiceError { check("result cannot be consumed twice", true) }
        let duplicate = PendingResult<Int>(discard: discarded.add)
        duplicate.complete(.success(4)); duplicate.complete(.success(5))
        check("duplicate callback discards its unclaimed value", discarded.values == [1, 2, 5])
        check("duplicate callback cannot replace the first result", try duplicate.take() == 4)
        let failed = PendingResult<Int>(discard: discarded.add)
        failed.complete(.failure(ServiceError(.accessibilityError, "fixture failure")))
        do { _ = try failed.take(); preconditionFailure("error was lost") }
        catch let e as ServiceError { check("callback error preserves its native code", e.code == .accessibilityError) }
        check("failed callbacks do not discard nonexistent resources", discarded.values == [1, 2, 5])
        for value in 100..<1100 {
            let box = PendingResult<Int>(discard: discarded.add), group = DispatchGroup()
            group.enter(); DispatchQueue.global().async { box.complete(.success(value)); group.leave() }
            group.enter(); DispatchQueue.global().async { box.abandon(); group.leave() }
            precondition(group.wait(timeout: .now() + 2) == .success, "race stalled")
        }
        let raced = discarded.values.filter { $0 >= 100 }
        check("1000 completion/cancellation races discard each resource once", raced.count == 1000 && Set(raced).count == 1000)
        print("\(count) asynchronous ownership checks passed")
    }
}
