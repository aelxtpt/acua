import Foundation

private final class RequestLog: @unchecked Sendable {
    struct Call: Sendable,Equatable { let connection:Int32;let windows:[UInt32] }
    private let lock=NSLock()
    private var storage=[Call]()
    private var failure=false
    func request(_ connection:Int32,_ windows:[UInt32])->Int32 {
        lock.withLock {
            storage.append(.init(connection:connection,windows:windows))
            if failure { failure=false;return -1000 }
            return 0
        }
    }
    func failNext() { lock.withLock { failure=true } }
    var calls:[Call] { lock.withLock { storage } }
}

@main enum WindowServerNotificationRequestsChecks {
    static func main() async throws {
        var rows=[[String:Any]]()
        func check(_ value:Bool,_ name:String) {
            rows.append(["name":name,"passed":value]);print("\(value ? "PASS" : "FAIL") \(name)")
        }
        let log=RequestLog(),broker=WindowServerNotificationRequests(api:.init(request:log.request))
        var a=broker.acquire(connection:7,windows:[30,10,10],requireSuccess:true)
        check(a != nil && log.calls.last == .init(connection:7,windows:[10,30]),"first consumer publishes sorted unique IDs")
        var b=broker.acquire(connection:7,windows:[20,30],requireSuccess:true)
        check(b != nil && log.calls.last == .init(connection:7,windows:[10,20,30]),"second consumer retains both owners' requested windows")
        var empty=broker.acquire(connection:7,windows:[],requireSuccess:false)
        check(empty != nil && log.calls.last?.windows == [10,20,30],"an empty request cannot erase other native consumers")
        var other=broker.acquire(connection:8,windows:[80],requireSuccess:true)
        check(other != nil && log.calls.last == .init(connection:8,windows:[80]),"connection ownership is independent")
        a=nil
        check(log.calls.last == .init(connection:7,windows:[20,30]),"releasing the first owner retains only the second owner's windows")
        b=nil
        check(log.calls.last == .init(connection:7,windows:[]),"removing the last nonempty owner clears stale native window IDs")
        empty=nil
        check(log.calls.last == .init(connection:7,windows:[]),"last empty lease also publishes the empty connection list")
        other=nil
        check(log.calls.last == .init(connection:8,windows:[]),"releasing an independent connection clears only that connection")
        var base=broker.acquire(connection:1,windows:[1,2],requireSuccess:true)
        check(base != nil,"rollback tests start with a live owner")
        log.failNext()
        let refused=broker.acquire(connection:1,windows:[3],requireSuccess:true)
        check(refused == nil,"a caller requiring success rejects a failed native request")
        check(Array(log.calls.suffix(2)) == [.init(connection:1,windows:[1,2,3]),.init(connection:1,windows:[1,2])],"failed native replacement restores the previous live owners atomically")
        log.failNext()
        var retained=broker.acquire(connection:1,windows:[4],requireSuccess:false)
        check(retained != nil && log.calls.last?.windows == [1,2,4],"an observer can retain its lease after an ignored native failure")
        var duplicate=broker.acquire(connection:1,windows:[4],requireSuccess:true)
        retained=nil
        check(duplicate != nil && log.calls.last?.windows == [1,2,4],"releasing one of two consumers of the same window retains the other")
        duplicate=nil;base=nil
        check(log.calls.last == .init(connection:1,windows:[]),"mixed success policies release all native IDs at final destruction")
        log.failNext()
        let failedFirst=broker.acquire(connection:9,windows:[99],requireSuccess:true)
        check(failedFirst == nil && Array(log.calls.suffix(2)) == [.init(connection:9,windows:[99]),.init(connection:9,windows:[])],"first failed acquisition rolls back to an empty list")
        var zero=broker.acquire(connection:0,windows:[0,10],requireSuccess:false)
        check(zero != nil && log.calls.last == .init(connection:0,windows:[0,10]),"broker preserves zero connection/window values accepted by consumers")
        zero=nil
        check(log.calls.last == .init(connection:0,windows:[]),"zero connection also releases its own native request")
        var anchor=broker.acquire(connection:12,windows:[500],requireSuccess:true)
        check(anchor != nil,"concurrent lifetime test starts with a surviving owner")
        await withTaskGroup(of:Void.self) { group in
            for id in UInt32(1)...100 {
                group.addTask {
                    let lease=broker.acquire(connection:12,windows:[id],requireSuccess:true)
                    await Task.yield()
                    withExtendedLifetime(lease) {}
                }
            }
        }
        let concurrent=log.calls.filter { $0.connection==12 }
        check(concurrent.count==201 && concurrent.allSatisfy { $0.windows.contains(500) },"one hundred concurrent acquisitions/releases never drop a surviving consumer")
        check(concurrent.last?.windows == [500],"all concurrent temporary owners are removed before the parent resumes")
        anchor=nil
        check(log.calls.last == .init(connection:12,windows:[]),"concurrent lifetime test ends with an empty native request")
        let ownLog=RequestLog()
        var own:WindowServerNotificationRequests?=WindowServerNotificationRequests(api:.init(request:ownLog.request))
        weak var weakBroker=own
        var survivor=own!.acquire(connection:2,windows:[2],requireSuccess:true)
        own=nil
        check(survivor != nil && weakBroker != nil,"an externally retained lease keeps its broker alive")
        survivor=nil
        check(weakBroker == nil && ownLog.calls.last == .init(connection:2,windows:[]),"final lease releases both native IDs and the broker without a cycle")
        weakBroker=nil
        let passed=rows.allSatisfy { $0["passed"] as? Bool == true }
        let result:[String:Any]=["passed":passed,"cases":rows.count,"results":rows,"nativeAPIExecuted":false]
        if CommandLine.arguments.count>1 { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
        if !passed { throw NSError(domain:"WindowServerNotificationRequestsChecks",code:1) }
    }
}
