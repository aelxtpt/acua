// Expected setup/query traces with owned framework replies; no screen or audio capture.
import Foundation
import ObjectiveC
import ScreenCaptureKit
import Darwin
private final class State<Value>: @unchecked Sendable {
    private let lock=NSLock();private var value:Value?
    func set(_ v:Value){lock.lock();value=v;lock.unlock()}
    var stored:Value? {lock.lock();defer{lock.unlock()};return value}
}
private typealias QueryCallback = @convention(block) (AnyObject?, NSError?) -> Void
private typealias QueryIMP = @convention(c) (AnyObject, Selector, Bool, Bool, @escaping QueryCallback) -> Void
private var queryImplementationAddress: UInt = 0
private let queryGate = QueryGate()
private final class EmptyContent: NSObject {
    @objc var displays: [AnyObject] { [] }
}
private final class QueryGate: @unchecked Sendable {
    private let lock=NSLock()
    private var callbacks=[QueryCallback]()
    private var flags=[[Bool]]()
    var count:Int {lock.lock();defer{lock.unlock()};return flags.count}
    var observed:[[Bool]] {lock.lock();defer{lock.unlock()};return flags}
    func receive(_ excluding:Bool,_ onScreen:Bool,_ callback:@escaping QueryCallback) {
        lock.lock();callbacks.append(callback);flags.append([excluding,onScreen]);lock.unlock()
    }
    func reply(empty:Bool) {
        lock.lock();precondition(!callbacks.isEmpty);let callback=callbacks.removeFirst();lock.unlock()
        if empty {callback(EmptyContent(),nil)}
        else {callback(nil,NSError(domain:"OwnedAudioSetup",code:43))}
    }
    func reset() {lock.lock();precondition(callbacks.isEmpty);flags=[];lock.unlock()}
}
private let queryStub:QueryIMP = {_,_,excluding,onScreen,callback in queryGate.receive(excluding,onScreen,callback)}
private func queryMethod()->Method {
    class_getClassMethod(SCShareableContent.self,NSSelectorFromString("getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:"))!
}

private let recorder=AudioRecorder.shared
private let owner=AudioRecorder.Owner(sessionID:"owned-session",senderPID:123,turnID:"owned-turn")
private func currentURL()->URL? {
    let optional=Mirror(reflecting:recorder).children.first(where:{$0.label=="recording"})!.value
    let record=Mirror(reflecting:optional).children.first?.value
    return record.flatMap {Mirror(reflecting:$0).children.first(where:{$0.label=="url"})?.value as? URL}
}
private func phase()->[String:Any] {
    let fields=Mirror(reflecting:recorder).children,url=currentURL()
    let finish=fields.first(where:{$0.label=="finishCapture"})!.value
    let task=fields.first(where:{$0.label=="autoStop"})!.value
    return ["hasURL":url != nil,"hasOwner":url != nil,"hasResource":!Mirror(reflecting:finish).children.isEmpty,
        "hasAutomaticTask":!Mirror(reflecting:task).children.isEmpty,
        "fileExists":url.map{FileManager.default.fileExists(atPath:$0.path)} ?? false]
}
private func files()->Set<URL> {
    let directory=FileManager.default.temporaryDirectory
    let enumerator=FileManager.default.enumerator(at:directory,includingPropertiesForKeys:nil)!
    return Set(enumerator.allObjects.compactMap{$0 as? URL}.filter{$0.pathExtension=="wav"})
}
private func output(after old:Set<URL>)->URL {
    if let url=currentURL(){return url}
    return files().subtracting(old).first!
}
private func wait(_ condition:()->Bool,seconds:Double=2) {
    let deadline=Date().addingTimeInterval(seconds)
    while !condition() && Date()<deadline {Thread.sleep(forTimeInterval:0.002)}
    precondition(condition())
}
private func call(_ milliseconds:Double=5000,_ operation:()->Void)throws {operation()}
private func outcome(_ operation:()throws->Void)->[String:Any] {
    do {try operation();return ["ok":true]}
    catch{return ["error":String(describing:error),"domain":(error as NSError).domain,"code":(error as NSError).code]}
}
private func start(duration:Int?=300_000,milliseconds:Double=5000)->[String:Any] {
    outcome {try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().timeIntervalSince1970*1000+milliseconds]) {
        try recorder.start(.init(maxDurationMilliseconds:duration),owner:owner)
    }}
}
private func stop(as caller:AudioRecorder.Owner=owner)->[String:Any] {
    do {
        let url=try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().timeIntervalSince1970*1000+150]) {try recorder.stop(owner:caller)}
        return ["url":url.path,"exists":FileManager.default.fileExists(atPath:url.path)]
    } catch{return ["error":String(describing:error),"domain":(error as NSError).domain,"code":(error as NSError).code]}
}
private func run()->[[String:Any]] {
    var rows=[[String:Any]]()
    for (name,duration,empty) in [("query-error",Optional(300_000),false),("no-display",Optional(300_000),true),("default-duration-error",nil,false)] {
        queryGate.reset();let done=State<[String:Any]>(),old=files()
        DispatchQueue.global().async{done.set(start(duration:duration))};wait{queryGate.count==1}
        let url=output(after:old),during=phase(),prefix="acua-computer-audio-",namePart=url.deletingPathExtension().lastPathComponent
        let shape=namePart.hasPrefix(prefix) && UUID(uuidString:String(namePart.dropFirst(prefix.count))) != nil && url.pathExtension=="wav"
        let outputExists=FileManager.default.fileExists(atPath:url.path)
        queryGate.reply(empty:empty);wait{done.stored != nil}
        rows.append(["name":name,"during":during,"outputNameHasExpectedShape":shape,"outputExistsDuringQuery":outputExists,
            "outputInTemporaryDirectory":url.deletingLastPathComponent().standardizedFileURL==FileManager.default.temporaryDirectory.standardizedFileURL,
            "queryFlags":queryGate.observed,"result":done.stored!,"after":phase(),"ownedURL":url.path])
    }
    for duration in [-1,0,99,300_001,Int.max] {
        queryGate.reset();let result=start(duration:duration)
        rows.append(["name":"invalid-duration-\(duration)","result":result,"queries":queryGate.count,"after":phase()])
    }
    for name in ["start-during-query","invalid-start-during-query","stop-during-query","wrong-owner-during-query","turn-during-query","wrong-turn-during-query"] {
        queryGate.reset();let done=State<[String:Any]>(),old=files()
        DispatchQueue.global().async{done.set(start())};wait{queryGate.count==1}
        let url=output(after:old),during=phase(),otherState=State<[String:Any]>()
        DispatchQueue.global().async {
            let other:[String:Any]
            switch name {
            case "start-during-query","invalid-start-during-query":other=start(duration:name.hasPrefix("invalid") ? 99:300_000,milliseconds:150)
            case "stop-during-query":other=stop()
            case "wrong-owner-during-query":other=stop(as:.init(sessionID:"other",senderPID:123))
            default:recorder.discardEndedTurn(threadID:"owned-session",turnID:name.hasPrefix("wrong") ? "other":"owned-turn");other=["ok":true]
            }
            otherState.set(other)
        }
        let limit=Date().addingTimeInterval(0.25)
        while otherState.stored==nil && Date()<limit {Thread.sleep(forTimeInterval:0.002)}
        let other=otherState.stored ?? ["didNotReturnBeforeSetupReply":true],afterOther=phase()
        queryGate.reply(empty:false);wait{done.stored != nil};wait{otherState.stored != nil}
        rows.append(["name":name,"during":during,"other":other,"afterOther":afterOther,"first":done.stored!,"after":phase(),"queries":queryGate.count,"ownedURL":url.path])
    }
    for discard in [false,true] {
        queryGate.reset();let first=State<[String:Any]>(),second=State<[String:Any]>(),old=files()
        DispatchQueue.global().async{first.set(start())};wait{queryGate.count==1}
        let url=output(after:old),otherState=State<[String:Any]>()
        DispatchQueue.global().async {
            if discard{recorder.discardEndedTurn(threadID:"owned-session",turnID:"owned-turn");otherState.set(["ok":true])}
            else{otherState.set(stop())}
        }
        let limit=Date().addingTimeInterval(0.25)
        while otherState.stored==nil && Date()<limit {Thread.sleep(forTimeInterval:0.002)}
        let other=otherState.stored ?? ["didNotReturnBeforeSetupReply":true]
        let previous=files()
        DispatchQueue.global().async{second.set(start())}
        let nextLimit=Date().addingTimeInterval(0.2)
        while queryGate.count<2 && Date()<nextLimit {Thread.sleep(forTimeInterval:0.002)}
        let before=phase(),publishedNextURL=currentURL()
        queryGate.reply(empty:false);wait{first.stored != nil};wait{otherState.stored != nil}
        wait{queryGate.count==2}
        let next=publishedNextURL ?? output(after:previous),after=phase(),claim=stop()
        queryGate.reply(empty:true);wait{second.stored != nil}
        rows.append(["name":discard ? "late-start-error-after-turn-and-restart":"late-start-error-after-stop-and-restart",
            "other":other,"afterReplacement":before,"first":first.stored!,"afterFirstCompletion":after,
            "claim":claim,"second":second.stored!,"after":phase(),"queries":queryGate.count,"ownedURL":url.path,"newOwnedURL":next.path])
    }
    return rows
}
private var ownedTemporaryDirectory:NSURL!
private typealias TemporaryDirectoryIMP = @convention(c) (AnyObject,Selector)->Unmanaged<NSURL>
private let temporaryDirectoryStub:TemporaryDirectoryIMP={_,_ in Unmanaged.passUnretained(ownedTemporaryDirectory)}
@main enum LocalStartProbe {
    static func main()throws {
        let own=FileManager.default.temporaryDirectory.appendingPathComponent("cua-owned-audio-start-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:own,withIntermediateDirectories:true)
        ownedTemporaryDirectory=own as NSURL
        let temporaryMethod=class_getInstanceMethod(FileManager.self,NSSelectorFromString("temporaryDirectory"))!
        let previousTemporary=method_getImplementation(temporaryMethod)
        method_setImplementation(temporaryMethod,unsafeBitCast(temporaryDirectoryStub,to:IMP.self))
        defer {
            method_setImplementation(temporaryMethod,previousTemporary)
            try? FileManager.default.removeItem(at:own)
        }
        guard FileManager.default.temporaryDirectory.standardizedFileURL==own.standardizedFileURL else {
            FileHandle.standardError.write(Data("Temporary directory override did not isolate output\n".utf8));exit(65)
        }
        let method=queryMethod(),original=method_getImplementation(queryMethod())
        queryImplementationAddress=UInt(bitPattern:original)
        method_setImplementation(method,unsafeBitCast(queryStub,to:IMP.self))
        defer {method_setImplementation(method,original)}
        let rows=run()
        try JSONSerialization.data(withJSONObject:["cases":rows,"realAudioRecordings":0,"realShareableContentQueries":0],options:[.prettyPrinted,.sortedKeys])
            .write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        let golden=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:Any]
        let expected=golden["cases"] as! [[String:Any]]
        precondition(rows.count==16 && expected.count==16)
        func normalize(_ value:Any,paths:[String:String])->Any {
            if let list=value as? [Any] {return list.map {normalize($0,paths:paths)}}
            guard let object=value as? [String:Any] else{return value}
            var result=object.filter{$0.key != "ownedURL" && $0.key != "newOwnedURL"}.mapValues{normalize($0,paths:paths)}
            if let url=result["url"] as? String,let owned=paths[url]{result["url"]=owned}
            if let error=result["error"] as? String,["invalidDuration","noActiveRecording","noDisplay","recordingAlreadyActive","recordingNotOwned"].contains(error){result.removeValue(forKey:"domain")}
            return result
        }
        for (row,expectedRow) in zip(rows,expected) {
            var paths=[String:String]()
            if let url=row["ownedURL"] as? String {paths[url]="<own output URL>"}
            if let url=row["newOwnedURL"] as? String {paths[url]="<new output URL>"}
            let actual=normalize(row,paths:paths) as! [String:Any]
            precondition(NSDictionary(dictionary:actual).isEqual(to:expectedRow),"Audio setup mismatch: \(row["name"]!)\n\(actual)\n\(expectedRow)")
            print("PASS audio setup: \(row["name"]!)")
        }
    }
}
