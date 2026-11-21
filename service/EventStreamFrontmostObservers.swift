import Foundation

//0x10078F3E8 /0x10078F47C /0x10078FDB4. An ordered strong token array is
// snapshotted under its lock and invoked after unlocking; removal is identity.
final class EventStreamFrontmostObservers<Application>:@unchecked Sendable {
    final class Token {
        fileprivate let handler:(Application)->Void
        fileprivate init(_ handler:@escaping (Application)->Void) {self.handler=handler}
    }
    private let lock=NSLock()
    private var observers:[Token]=[]
    func add(_ handler:@escaping (Application)->Void)->Token {
        let token=Token(handler)
        lock.lock();observers.append(token);lock.unlock()
        return token
    }
    func remove(_ token:Token) {
        lock.lock();observers.removeAll {$0 === token};lock.unlock()
    }
    func publish(_ application:Application) {
        lock.lock();let snapshot=observers;lock.unlock()
        for observer in snapshot {observer.handler(application)}
    }
}
