import Foundation
import Darwin

final class Box<T>:@unchecked Sendable {
    private let lock=NSLock();private var value:T
    init(_ value:T){self.value=value}
    func get()->T{lock.lock();defer{lock.unlock()};return value}
    func set(_ value:T){lock.lock();self.value=value;lock.unlock()}
}
private final class WeakBox:@unchecked Sendable {weak var value:AnyObject?;init(_ value:AnyObject){self.value=value}}
private final class Payload{}
private final class Gate:@unchecked Sendable {
    private let lock=NSLock();private var waiter:CheckedContinuation<Void,Never>?,opened=false
    func wait()async {await withCheckedContinuation{continuation in
        lock.lock();if opened{lock.unlock();continuation.resume()}else{waiter=continuation;lock.unlock()}
    }}
    func open(){lock.lock();opened=true;let callback=waiter;waiter=nil;lock.unlock();callback?.resume()}
}
private final class Queue:@unchecked Sendable {
    typealias Operation=@Sendable()async->Void
    var local:AsyncSerialQueue?=AsyncSerialQueue()
    init(_ unused:UInt64?){}
    var object:AnyObject{local!}
    func field<T>(_ name:String,_ type:T.Type)->T {
        Mirror(reflecting:object).children.first{$0.label==name}!.value as! T
    }
    func enqueue(_ operation:@escaping Operation) {
        local!.async(operation)
    }
    func sync()async throws->Int {
        return try await local!.sync{42}
    }
    func release(){local=nil}
}
private func wait(_ condition:()->Bool)async throws {
    let deadline=ContinuousClock.now.advanced(by:.seconds(2))
    while !condition(){guard ContinuousClock.now<deadline else{throw NSError(domain:"OwnedQueueTimeout",code:1)};try await Task.sleep(for:.milliseconds(2))}
}

func lifecycleCases(_ base:UInt64?)async throws->[String:Any] {
    var rows=[[String:Any]]()
    do {
        let queue=Queue(base),weak=WeakBox(queue.object),worker=queue.field("task",Task<Void,Never>.self)
        queue.release();await worker.value
        rows.append(["name":"idle-release","released":weak.value==nil,"workerCancelled":worker.isCancelled])
    }
    do {
        let queue=Queue(base),weak=WeakBox(queue.object),worker=queue.field("task",Task<Void,Never>.self)
        let entered=Box(false),cancelled=Box(false),completed=Box(false)
        queue.enqueue {
            entered.set(true)
            do{try await Task.sleep(for:.seconds(10))}catch{cancelled.set(error is CancellationError)}
            completed.set(true)
        }
        try await wait{entered.get()};queue.release();await worker.value
        rows.append(["name":"running-sleep-release","released":weak.value==nil,"workerCancelled":worker.isCancelled,"operationCancelled":cancelled.get(),"operationCompleted":completed.get()])
    }
    do {
        let queue=Queue(base),weak=WeakBox(queue.object),worker=queue.field("task",Task<Void,Never>.self)
        let entered=Box(false),completed=Box(false),cancelled=Box(false),gate=Gate()
        queue.enqueue {entered.set(true);await gate.wait();cancelled.set(Task.isCancelled);completed.set(true)}
        try await wait{entered.get()};queue.release()
        let before:[String:Any]=["released":weak.value==nil,"operationCompleted":completed.get(),"workerCancelled":worker.isCancelled]
        gate.open();await worker.value
        rows.append(["name":"running-noncancellable-gate-release","beforeGate":before,"operationCompleted":completed.get(),"operationCancelled":cancelled.get()])
    }
    do {
        let queue=Queue(base),weak=WeakBox(queue.object),worker=queue.field("task",Task<Void,Never>.self)
        let gate=Gate(),entered=Box(false),executed=Box(0)
        queue.enqueue{entered.set(true);await gate.wait()};try await wait{entered.get()}
        var references=[WeakBox]()
        for _ in 0..<4 {
            let payload=Payload();references.append(WeakBox(payload))
            queue.enqueue{withExtendedLifetime(payload){};executed.set(executed.get()+1)}
        }
        queue.release();let released=weak.value==nil
        gate.open();await worker.value
        rows.append(["name":"buffered-jobs-release","released":released,"executed":executed.get(),"payloadsReleased":references.allSatisfy{$0.value==nil}])
    }
    do {
        let queue=Queue(base),worker=queue.field("task",Task<Void,Never>.self)
        let continuation=queue.field("continuation",AsyncStream<Queue.Operation>.Continuation.self)
        continuation.finish();await worker.value
        let result=Box<[String:Any]?>(nil)
        Task.detached {
            do{let value=try await queue.sync();result.set(["value":value])}
            catch{result.set(["cancellationError":error is CancellationError,"error":String(describing:error)])}
        }
        let deadline=ContinuousClock.now.advanced(by:.milliseconds(500))
        while result.get()==nil && ContinuousClock.now<deadline{try await Task.sleep(for:.milliseconds(2))}
        rows.append(["name":"sync-after-stream-finished","completedWithinObservation":result.get() != nil,"result":result.get() ?? [:]])
    }
    return ["cases":rows,"nativeInput":false,"realScreenshots":0]
}

@main enum QueueLifecycleTests {
    static func main()async throws {
        let result=try await lifecycleCases(nil)
        let expected=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let rows=result["cases"] as! [[String:Any]],golden=expected["cases"] as! [[String:Any]]
        precondition(rows.count==5 && golden.count==5)
        for (actual,expected) in zip(rows,golden) {
            precondition((actual as NSDictionary).isEqual(to:expected),"Queue lifecycle differs: \(actual["name"]!)")
            print("PASS queue lifecycle \(actual["name"]!)")
        }
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
    }
}
