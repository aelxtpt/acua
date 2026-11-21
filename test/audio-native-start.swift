// Expected recorder/CaptureStream traces with owned SDK replies and empty WAV files.
import Foundation
import ScreenCaptureKit
import ObjectiveC

private let nativeOwner=AudioRecorder.Owner(sessionID:"owned-session",senderPID:123,turnID:"owned-turn")
private func recorder()->AudioRecorder {AudioRecorder()}
private func currentURL(_ recorder:AudioRecorder)->URL? {
    let optional=Mirror(reflecting:recorder).children.first(where:{$0.label=="recording"})!.value
    let value=Mirror(reflecting:optional).children.first?.value
    return value.flatMap{Mirror(reflecting:$0).children.first(where:{$0.label=="url"})?.value as? URL}
}
private func phase(_ recorder:AudioRecorder)->[String:Any] {
    let fields=Mirror(reflecting:recorder).children
    let optional=fields.first(where:{$0.label=="recording"})!.value
    let value=Mirror(reflecting:optional).children.first?.value
    let automatic=value.flatMap{Mirror(reflecting:$0).children.first(where:{$0.label=="didAutoStop"})?.value as? Bool} ?? false
    let finish=fields.first(where:{$0.label=="finishCapture"})!.value,task=fields.first(where:{$0.label=="autoStop"})!.value
    return ["hasURL":value != nil,"hasOwner":value != nil,"hasResource":!Mirror(reflecting:finish).children.isEmpty,
        "hasAutomaticTask":!Mirror(reflecting:task).children.isEmpty,"autoStopped":automatic]
}
private func start(_ recorder:AudioRecorder)->[String:Any] {
    do {try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().timeIntervalSince1970*1000+5000]){try recorder.start(.init(maxDurationMilliseconds:300_000),owner:nativeOwner)};return ["ok":true]}
    catch{return nativeError(error)}
}
private func stop(_ recorder:AudioRecorder,as owner:AudioRecorder.Owner=nativeOwner)->[String:Any] {
    do {let url=try RequestRuntime.withRequest(["deadlineUnixMilliseconds":Date().timeIntervalSince1970*1000+150]){try recorder.stop(owner:owner)};return ["url":url.path,"exists":FileManager.default.fileExists(atPath:url.path)]}
    catch{return nativeError(error)}
}
private func wait(_ condition:()->Bool) {
    let limit=ProcessInfo.processInfo.systemUptime+3
    while !condition() && ProcessInfo.processInfo.systemUptime<limit{Thread.sleep(forTimeInterval:0.002)}
    precondition(condition())
}
private func settle(_ streams:[NativeOwnedStream]) {
    let limit=ProcessInfo.processInfo.systemUptime+1
    var last=streams.map{$0.stops.get()},stable=ProcessInfo.processInfo.systemUptime
    while ProcessInfo.processInfo.systemUptime<limit {
        let current=streams.map{$0.stops.get()}
        if current != last{last=current;stable=ProcessInfo.processInfo.systemUptime}
        if ProcessInfo.processInfo.systemUptime-stable>0.05{return}
        Thread.sleep(forTimeInterval:0.002)
    }
}
private func run()->[String:Any] {
    let fixture=NativeFixture.shared;var rows=[[String:Any]]()
    let names=["success","start-error","add-error","writer-error","stop-during-start-success","stop-during-start-error","wrong-owner-during-start","start-during-start","turn-during-start-success","turn-during-start-error","stop-error-during-start","restart-after-stop-old-success","restart-after-stop-old-error","restart-after-turn-old-success","restart-after-turn-old-error"]
    for name in names {
        fixture.options.edit{$0=(add:name=="add-error",stop:name=="stop-error-during-start")}
        if name=="writer-error" {
            let directory=fixture.directory!,file=(directory as URL).appendingPathComponent("owned-readonly",isDirectory:true)
            try! FileManager.default.createDirectory(at:file,withIntermediateDirectories:true)
            try! FileManager.default.setAttributes([.posixPermissions:0o500],ofItemAtPath:file.path)
            precondition(!FileManager.default.isWritableFile(atPath:file.path))
            fixture.directory=file as NSURL
            let instance=recorder(),result=start(instance)
            fixture.directory=directory
            try! FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:file.path)
            rows.append(["name":name,"result":result,"after":phase(instance),"claim":stop(instance)])
            continue
        }
        let firstIndex=fixture.streams.get().count,instance=recorder(),first=Locked<[String:Any]?>(nil)
        DispatchQueue.global().async{let value=start(instance);first.edit{$0=value}}
        wait{fixture.streams.get().count>firstIndex}
        let stream=fixture.streams.get()[firstIndex]
        if name=="add-error" {
            wait{first.get() != nil};settle([stream])
            rows.append(["name":name,"result":first.get()!,"after":phase(instance),"startCalls":stream.starts.get(),"stopCalls":stream.stops.get(),"addCalls":stream.adds.get(),"configuration":stream.configuration,"outputTypes":stream.outputTypes.get(),"queuePresent":stream.queuePresent.get(),"claim":stop(instance),"fileExistsAfterCleanup":FileManager.default.fileExists(atPath:stream.outputURL.path),"wave":waveInfo(stream.outputURL),"ownedURL":stream.outputURL.path])
            continue
        }
        wait{stream.starts.get()==1}
        let url=currentURL(instance)!,during=phase(instance)
        let exists=FileManager.default.fileExists(atPath:url.path),intervention:[String:Any]
        if name.hasPrefix("stop-") || name.hasPrefix("restart-after-stop"){intervention=stop(instance)}
        else if name.hasPrefix("turn-") || name.hasPrefix("restart-after-turn"){
            instance.discardEndedTurn(threadID:"owned-session",turnID:"owned-turn");intervention=["ok":true]
        }else if name=="wrong-owner-during-start"{intervention=stop(instance,as:.init(sessionID:"other",senderPID:123))}
        else if name=="start-during-start"{intervention=start(instance)}
        else{intervention=["none":true]}
        let afterIntervention=phase(instance),callsDuring=stream.stops.get()
        let second=Locked<[String:Any]?>(nil);var next:NativeOwnedStream?,nextURL:URL?,replacementPhase:[String:Any]?
        if name.hasPrefix("restart-"){
            fixture.options.edit{$0=(false,false)}
            DispatchQueue.global().async{let value=start(instance);second.edit{$0=value}}
            wait{fixture.streams.get().count>firstIndex+1}
            next=fixture.streams.get()[firstIndex+1];wait{next!.starts.get()==1}
            nextURL=currentURL(instance)!;replacementPhase=phase(instance)
        }
        stream.releaseStart(failure:name.hasSuffix("error"));wait{first.get() != nil}
        let afterFirst=phase(instance)
        if let next{next.releaseStart(failure:false);wait{second.get() != nil}}
        let after=phase(instance),claim=stop(instance)
        settle([stream]+(next.map{[$0]} ?? []))
        var row:[String:Any]=["name":name,"duringStart":during,"fileExistsDuringStart":exists,"intervention":intervention,
            "afterIntervention":afterIntervention,"stopCallsBeforeStartReply":callsDuring,"first":first.get()!,"afterFirstCompletion":afterFirst,"after":after,
            "claim":claim,"oldFileExists":FileManager.default.fileExists(atPath:url.path),"wave":waveInfo(url),
            "startCalls":stream.starts.get(),"stopCalls":stream.stops.get(),"addCalls":stream.adds.get(),"configuration":stream.configuration,
            "outputTypes":stream.outputTypes.get(),"queuePresent":stream.queuePresent.get(),"outputAliveAfterCleanup":stream.output != nil,"ownedURL":url.path]
        if let next,let nextURL,let replacementPhase{
            row["second"]=second.get()!;row["afterReplacement"]=replacementPhase;row["newStartCalls"]=next.starts.get();row["newStopCalls"]=next.stops.get()
            row["newFileExists"]=FileManager.default.fileExists(atPath:nextURL.path);row["newWave"]=waveInfo(nextURL);row["newOutputAliveAfterCleanup"]=next.output != nil;row["newOwnedURL"]=nextURL.path
        }
        rows.append(row)
    }
    return ["cases":rows,"queryFlags":fixture.queryFlags.get(),"realAudioRecordings":0,"realAudioSamples":0,"uninitializedSDKReceiversOwnedUntilProcessExit":fixture.allocatedReceivers.get().count]
}
@main enum NativeStartTests {
    static func main()throws{
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("cua-owned-native-start-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:directory)}
        let restore=installNativeFixture(directory);defer{restore()}
        let result=run()
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        let golden=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))) as! [String:Any]
        let rows=result["cases"] as! [[String:Any]],expected=golden["cases"] as! [[String:Any]]
        precondition(rows.count==15 && expected.count==15)
        precondition(NSArray(array:result["queryFlags"] as! [[Bool]]).isEqual(to:golden["queryFlags"] as! [Any]))
        func normalize(_ value:Any,paths:[String:String])->Any {
            if let list=value as? [Any]{return list.map{normalize($0,paths:paths)}}
            guard let object=value as? [String:Any] else{return value}
            var result=object.filter{$0.key != "ownedURL" && $0.key != "newOwnedURL"}.mapValues{normalize($0,paths:paths)}
            if let url=result["url"] as? String,let owned=paths[url]{result["url"]=owned}
            if let error=result["error"] as? String,["invalidDuration","noActiveRecording","noDisplay","recordingAlreadyActive","recordingNotOwned"].contains(error){result.removeValue(forKey:"domain")}
            return result
        }
        for (row,expectedRow) in zip(rows,expected) {
            var paths=[String:String]()
            if let url=row["ownedURL"] as? String{paths[url]="<own output URL>"}
            if let url=row["newOwnedURL"] as? String{paths[url]="<new output URL>"}
            let actual=normalize(row,paths:paths) as! [String:Any]
            precondition(NSDictionary(dictionary:actual).isEqual(to:expectedRow),"Native audio mismatch: \(row["name"]!)\n\(actual)\n\(expectedRow)")
            print("PASS native audio start: \(row["name"]!)")
        }

    }
}
