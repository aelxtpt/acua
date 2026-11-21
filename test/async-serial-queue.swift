import Foundation
private final class Trace: @unchecked Sendable {
 let lock=NSLock();private var items=[String]()
 func add(_ item:String){lock.lock();defer{lock.unlock()};items.append(item)}
 var values:[String]{lock.lock();defer{lock.unlock()};return items}
}
private enum Context { @TaskLocal static var value="none" }
private enum SampleError:Error,Equatable{case failed(Int)}
@main enum QueueSyncTests {
 static func main() async throws {
  var checks=0
  func check(_ name:String,_ value:Bool){precondition(value,name);checks+=1;print("PASS: "+name)}
  let trace=Trace(), queue=Context.$value.withValue("queue-owner"){AsyncSerialQueue()}
  queue.async{trace.add("first-start");try? await Task.sleep(for:.milliseconds(20));trace.add("first-end")}
  let value=try await queue.sync{trace.add("sync");return "result 🙂"}
  check("queued sync waits for the previous async job",trace.values==["first-start","first-end","sync"])
  check("generic result survives the continuation",value=="result 🙂")
  let large=try await queue.sync{[String](repeating:"owned",count:100)}
  check("nontrivial generic result retains value storage",large.count==100 && large.last=="owned")
  do {let _:Int=try await queue.sync{throw SampleError.failed(42)};preconditionFailure("Expected operation error")}
  catch SampleError.failed(let number){check("operation error propagates intact",number==42)}
  let after=try await queue.sync{21*2}
  check("throwing job leaves the serial worker usable",after==42)
  let local=try await Context.$value.withValue("caller"){try await queue.sync{Context.value}}
  check("worker preserves queue initializer TaskLocal context",local=="queue-owner")
  if #available(macOS 26.0, *) {
   let pair=AsyncStream<Void>.makeStream();let started=Trace()
   let lowQueue=await Task.detached(priority:.background){AsyncSerialQueue()}.value
   let caller=Task.detached(priority:.background) {
    try await lowQueue.sync {
     started.add("started")
     var iterator=pair.stream.makeAsyncIterator();_ = await iterator.next()
     return Task.currentPriority
    }
   }
   let limit=ContinuousClock.now.advanced(by:.seconds(5))
   while started.values.isEmpty {precondition(ContinuousClock.now<limit);try await Task.sleep(for:.milliseconds(5))}
   caller.escalatePriority(to:.high)
   pair.continuation.yield(());pair.continuation.finish()
   let priority=try await caller.value
   check("later caller priority escalation reaches the suspended worker",priority>=TaskPriority.high)
   let freshQueue=await Task.detached(priority:.background){AsyncSerialQueue()}.value
   let highCaller=Task.detached(priority:.high){try await freshQueue.sync{Task.currentPriority}}
   let high=try await highCaller.value
   check("initial caller priority escalates the queue worker",high>=TaskPriority.high)
  }
  let cancelQueue=AsyncSerialQueue(),cancelGate=AsyncStream<Void>.makeStream(),cancelStarted=Trace()
  cancelQueue.async {
   cancelStarted.add("waiting")
   var iterator=cancelGate.stream.makeAsyncIterator();_ = await iterator.next()
  }
  let pending=Task.detached {try await cancelQueue.sync{Task.isCancelled}}
  let cancelDeadline=ContinuousClock.now.advanced(by:.seconds(5))
  while cancelStarted.values.isEmpty {precondition(ContinuousClock.now<cancelDeadline);try await Task.sleep(for:.milliseconds(2))}
  pending.cancel();cancelGate.continuation.yield(());cancelGate.continuation.finish()
  let workerCancelled=try await pending.value
  check("caller cancellation does not cancel the enqueued worker job",!workerCancelled)
  try await queue.sync{trace.add("void-complete")}
  check("Void result completes after its operation",trace.values.last=="void-complete")
  print("\(checks) queue sync checks passed")
 }
}
