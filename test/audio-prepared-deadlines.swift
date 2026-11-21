// Local cancellation and deadline checks for prepared audio requests.
import Foundation
import Darwin

private final class Gate<Value>:@unchecked Sendable {
    private let lock=NSLock();private var continuation:CheckedContinuation<Value,Never>?
    private var value:Value?
    private var opened=false
    func wait()async->Value{await withCheckedContinuation{pending in
        lock.lock()
        if opened{let result=value!;lock.unlock();pending.resume(returning:result)}
        else{continuation=pending;lock.unlock()}
    }}
    func open(_ result:Value){lock.lock();precondition(!opened);opened=true;value=result;let pending=continuation;continuation=nil;lock.unlock();pending?.resume(returning:result)}
}
private func wait(_ condition:()->Bool) {
    let limit=ProcessInfo.processInfo.systemUptime+5
    while !condition() && ProcessInfo.processInfo.systemUptime<limit{Thread.sleep(forTimeInterval:0.002)}
    precondition(condition())
}
private func state(_ recorder:AudioRecorder)->[String:Bool] {
    let fields=Mirror(reflecting:recorder).children
    return ["recording":!Mirror(reflecting:fields.first(where:{$0.label=="recording"})!.value).children.isEmpty,
        "resource":!Mirror(reflecting:fields.first(where:{$0.label=="finishCapture"})!.value).children.isEmpty,
        "automaticTask":!Mirror(reflecting:fields.first(where:{$0.label=="autoStop"})!.value).children.isEmpty]
}
private func fileIdentity(_ url:URL)->stat {
    var value=stat();precondition(lstat(url.path,&value)==0);return value
}
private func hasOpenDescriptor(_ identity:stat)->Bool {
    let names=(try? FileManager.default.contentsOfDirectory(atPath:"/dev/fd")) ?? []
    return names.compactMap{Int32($0)}.contains{descriptor in
        var value=stat()
        return fstat(descriptor,&value)==0 && value.st_dev==identity.st_dev && value.st_ino==identity.st_ino
    }
}
@main enum PreparedDeadlineTests {
    static func main()throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("cua-owned-prepared-deadline-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let restore=installNativeFixture(directory);defer{restore()}
        let fixture=NativeFixture.shared,owner=AudioRecorder.Owner(sessionID:"owned-session",senderPID:123)
        var rows=[[String:Any]]()
        for cancelled in [false,true] {
            let name=cancelled ? "cancel-after-resource-publication":"deadline-after-resource-publication"
            let recorder=AudioRecorder(),cancel=Locked(false),result=Locked<String?>(nil),index=fixture.streams.get().count
            DispatchQueue.global().async {
                let outcome:String
                do {
                    try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().timeIntervalSince1970*1000+(cancelled ? 10_000:2_000)],cancelled:{cancel.get()}) {
                        try recorder.start(.init(maxDurationMilliseconds:300_000),owner:owner)
                    }
                    outcome="unexpected success"
                } catch let error as ServiceError {outcome=error.message}
                catch {outcome=String(describing:error)}
                result.edit{$0=outcome}
            }
            wait{fixture.streams.get().count>index}
            let stream=fixture.streams.get()[index];wait{stream.starts.get()==1}
            let before=state(recorder),identity=fileIdentity(stream.outputURL)
            precondition(before["recording"]==true && before["resource"]==true && hasOpenDescriptor(identity))
            if cancelled{cancel.edit{$0=true}}
            wait{result.get() != nil};wait{stream.stops.get()==1}
            wait{!hasOpenDescriptor(identity)}
            let after=state(recorder),fileExists=FileManager.default.fileExists(atPath:stream.outputURL.path)
            precondition(after.values.allSatisfy{!$0} && !fileExists)
            precondition(result.get()==(cancelled ? "Request cancelled":"Request deadline exceeded"))
            stream.releaseStart(failure:false)
            wait{stream.output==nil}
            precondition(state(recorder).values.allSatisfy{!$0} && stream.stops.get()==1 && !FileManager.default.fileExists(atPath:stream.outputURL.path))
            rows.append(["name":name,"error":result.get()!,"before":before,"after":after,"stopCalls":stream.stops.get(),"latePublication":false,"fileExists":false,"writerClosedBeforeLateCallback":true])
            print("PASS prepared audio ownership: \(name)")
        }
        do {
            let recorder=AudioRecorder(),result=Locked<String?>(nil),index=fixture.streams.get().count
            fixture.holdQuery.edit{$0=true}
            DispatchQueue.global().async {
                let outcome:String
                do {
                    try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().timeIntervalSince1970*1000+2_000]){
                        try recorder.start(.init(maxDurationMilliseconds:300_000),owner:owner)
                    };outcome="unexpected success"
                }catch let error as ServiceError{outcome=error.message}
                catch{outcome=String(describing:error)}
                result.edit{$0=outcome}
            }
            wait{!fixture.heldQueries.get().isEmpty};wait{result.get() != nil}
            precondition(result.get()=="Request deadline exceeded" && state(recorder).values.allSatisfy{!$0})
            fixture.releaseQuery()
            let limit=ProcessInfo.processInfo.systemUptime+0.1
            while ProcessInfo.processInfo.systemUptime<limit{Thread.sleep(forTimeInterval:0.002)}
            precondition(fixture.streams.get().count==index && state(recorder).values.allSatisfy{!$0})
            rows.append(["name":"deadline-before-resource-publication","error":result.get()!,"streamsCreated":0,"latePublication":false])
            print("PASS prepared audio ownership: deadline-before-resource-publication")
        }
        do {
            let gate=Gate<Int>(),entered=DispatchSemaphore(value:0),result=Locked<String?>(nil)
            let published=Locked(0),begun=Locked(0),finished=Locked(0),abandoned=Locked(0)
            DispatchQueue.global().async {
                let outcome:String
                do {
                    let _:AudioCaptureBridge<Int>=try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().timeIntervalSince1970*1000+60]){
                        try AudioCaptureBridge.startPrepared(prepare:{entered.signal();return await gate.wait()},publish:{_ in published.edit{$0 += 1}},begin:{_ in begun.edit{$0 += 1}},finish:{_ in finished.edit{$0 += 1}},abandon:{abandoned.edit{$0 += 1}})
                    };outcome="unexpected success"
                }catch let error as ServiceError{outcome=error.message}
                catch{outcome=String(describing:error)}
                result.edit{$0=outcome}
            }
            precondition(entered.wait(timeout:.now()+2) == .success)
            wait{result.get() != nil};precondition(result.get()=="Request deadline exceeded" && abandoned.get()==1)
            gate.open(73);wait{finished.get()==1}
            precondition(published.get()==0 && begun.get()==0 && abandoned.get()==1)
            rows.append(["name":"late-prepared-resource","error":result.get()!,"published":published.get(),"begun":begun.get(),"finished":finished.get(),"abandoned":abandoned.get()])
            print("PASS prepared audio ownership: late-prepared-resource")
        }
        try JSONSerialization.data(withJSONObject:["cases":rows,"realAudioRecordings":0],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    }
}
