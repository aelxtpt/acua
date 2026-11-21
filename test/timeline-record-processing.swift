import Foundation
import CoreFoundation

private final class MemoryDefaults:UserDefaults,@unchecked Sendable {
    var values:[String:Any]=[:],calls=[[String:Any]]()
    override func object(forKey key:String)->Any?{calls.append(["kind":"get","key":key]);return values[key]}
    override func set(_ value:Any?,forKey key:String){calls.append(["kind":"set","key":key]);values[key]=value}
    override func removeObject(forKey key:String){calls.append(["kind":"remove","key":key]);values.removeValue(forKey:key)}
}
private final class ForbiddenProducer:EventStreamCaptureProducing {
    typealias Application=String
    var isRecording:Bool{fatalError("Paused fixture touched native producer")}
    var onRecordStored:((EventStreamRecord)->Void)?
    var onSuppressedRecordStored:((EventStreamRecord)->Void)?
    var shouldCaptureApplication:((String)->Bool)?
    func start()throws{fatalError("Paused fixture started capture")}
    func stop(emitSessionEnded:Bool){fatalError("Paused fixture stopped capture")}
    func refreshCurrentApplication(){fatalError("Paused fixture refreshed capture")}
    func flushPendingRecords(){fatalError("Paused fixture flushed capture")}
    func makeSessionBoundaryRecord(kind:EventStreamEventKind)->EventStreamRecord{fatalError("Paused fixture emitted a record")}
}
private final class Observation:@unchecked Sendable {var rows=[[String:Any]]()}
private func json(_ value:Any)throws->Data{try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed])}
private func encoded(_ value:TimelineStatus)throws->[String:Any]{try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))as![String:Any]}
private func normalized(_ value:Any,root:String)->Any {
    if let value=value as?String{return value.replacingOccurrences(of:root,with:"$ROOT")}
    if let value=value as?[String:Any]{return value.mapValues{normalized($0,root:root)}}
    if let value=value as?[Any]{return value.map{normalized($0,root:root)}}
    return value
}
private func errorJSON(_ value:Any)->Any {
    if let error=value as?NSError{return ["domain":error.domain,"code":error.code,"userInfo":error.userInfo.mapValues(errorJSON)]}
    if let url=value as?URL{return url.absoluteString}
    if let values=value as?[String:Any]{return values.mapValues(errorJSON)}
    if let values=value as?[Any]{return values.map(errorJSON)}
    if value is String || value is NSNumber || value is NSNull{return value}
    return String(reflecting:value)
}
private func comparableFailure(_ value:[String:Any])->[String:Any] {
    if (value["domain"]as?String)?.contains("TimelineError")==true {
        return ["kind":"TimelineError","code":value["code"]!,"reflected":value["reflected"]!,"userInfo":value["userInfo"]!]
    }
    var value=value
    // NSError reflection contains transient underlying-error object addresses.
    // Preserve the complete structured domain/code/userInfo/description instead.
    if value["domain"]as?String==NSCocoaErrorDomain{value.removeValue(forKey:"reflected")}
    return value
}
private func failure(_ error:Error)->[String:Any] {
    let native=error as NSError
    return comparableFailure(["domain":native.domain,"code":native.code,"userInfo":native.userInfo.mapValues(errorJSON),"reflected":String(reflecting:error),"description":native.localizedDescription])
}
private func fixture(_ item:[String:Any],home:URL)throws {
    for name in item["directories"]as?[String] ?? []{try FileManager.default.createDirectory(at:home.appendingPathComponent(name,isDirectory:true),withIntermediateDirectories:true)}
    for (name,text) in item["files"]as?[String:String] ?? [:]{let url=home.appendingPathComponent(name);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true);try Data(text.utf8).write(to:url)}
}
private func snapshot(_ home:URL)throws->[String:Any] {
    var directories=[String](),files=[String:String]()
    if let enumerator=FileManager.default.enumerator(at:home,includingPropertiesForKeys:[.isDirectoryKey]){for case let url as URL in enumerator {
        precondition(url.path.hasPrefix(home.path+"/"))
        let name=String(url.path.dropFirst(home.path.count+1))
        if (try url.resourceValues(forKeys:[.isDirectoryKey])).isDirectory==true{directories.append(name)}
        else{files[name]=(try String(contentsOf:url,encoding:.utf8)).replacingOccurrences(of:home.path,with:"$ROOT")}
    }}
    return ["directories":directories.sorted(),"files":files]
}
private func represent(_ value:Any)->Any{if let date=value as?Date{return ["dateUnix":date.timeIntervalSince1970]};return value}

@MainActor private struct ForbiddenURLFilter:EventStreamRecordFilter {
    func disposition(for record:EventStreamRecord)async->EventStreamRecordDisposition{fatalError("Unexpected URL policy lookup")}
}
private func application(_ app:EventStreamObservedApplication)->[String:Any] {
    ["id":app.id,"name":app.name,"bundleIdentifier":app.bundleIdentifier.map{$0 as Any} ?? NSNull(),
     "bundleURL":app.bundleURL.map{$0.absoluteString as Any} ?? NSNull(),"executableURL":app.executableURL.map{$0.absoluteString as Any} ?? NSNull()]
}
@MainActor private func recents(_ store:TimelineRecentApplicationStore)->[[String:Any]] {
    store.entries.map{entry in ["application":application(entry.application),"lastSession":["application":application(entry.lastSession.application),
        "startedAt":entry.lastSession.startedAt.timeIntervalSinceReferenceDate,"endedAt":entry.lastSession.endedAt.map{$0.timeIntervalSinceReferenceDate as Any} ?? NSNull()],
        "urlDomains":entry.urlDomains.map{["domain":$0.domain,"isExcluded":$0.isExcluded,"lastSeenAt":$0.lastSeenAt.timeIntervalSinceReferenceDate]as[String:Any]},
        "isExcluded":entry.isExcluded,"lastSeenAt":entry.lastSeenAt.timeIntervalSinceReferenceDate]}
}
private func writerState(_ writer:TimelineSegmentWriter?)->[String:Any] {
    guard let writer else{return [:]}
    return ["id":writer.currentSegment.id,"startedAt":writer.currentSegment.startedAt.timeIntervalSinceReferenceDate,
        "eventCount":writer.currentSegment.eventCount.map{$0 as Any} ?? NSNull(),"suppressedEventCount":writer.currentSegment.suppressedEventCount.map{$0 as Any} ?? NSNull(),
        "mainHandlePresent":writer.segmentFileHandle != nil,"suppressedHandlePresent":writer.suppressedFileHandle != nil]
}
@main private enum Main {
    @MainActor static func main()throws {
        let inputURL=URL(fileURLWithPath:CommandLine.arguments[1])
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:inputURL))as![String:Any]
        let rows=(reference["payload"]as![String:Any])["rows"]as![[String:Any]]
        let nativeRoot=URL(fileURLWithPath:reference["fixture_directory"]as!String).appendingPathComponent("fixtures",isDirectory:true)
        let template=reference["instructionsTemplate"]as!String
        let localRoot=URL(fileURLWithPath:"/private/tmp/cua-timeline-record-comparison-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:localRoot,withIntermediateDirectories:true)
        defer{try?FileManager.default.removeItem(at:localRoot)}
        var passed=0,failed=0
        for (rowIndex,row)in rows.enumerated() {
            let home=localRoot.appendingPathComponent(String(rowIndex),isDirectory:true),expectedHome=nativeRoot.appendingPathComponent(String(rowIndex),isDirectory:true)
            try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
            let input=row["input"]as![String:Any]
            if let settings=input["settings"] {
                let url=home.appendingPathComponent("timeline/settings.json")
                try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
                try JSONSerialization.data(withJSONObject:settings,options:.sortedKeys).write(to:url)
            }
            let defaults=MemoryDefaults()
            defaults.values["timeline.pauseResumeDate"]=Date(timeIntervalSince1970:input["initialDate"]as!Double)
            let eventRoot=home.appendingPathComponent("eventstream",isDirectory:true)
            let resources=TimelineResourcePreparation(eventStreamRootURL:eventRoot,configurationRootURL:home.appendingPathComponent("timeline",isDirectory:true),memoryExtensionURL:home.appendingPathComponent("memories/extensions/timeline",isDirectory:true),loadInstructions:{template})
            let settings=TimelineSettingsCache(configurationRootURL:home.appendingPathComponent("timeline",isDirectory:true))
            let recent=TimelineRecentApplicationStore()
            var processor:TimelineRecordProcessor!,now=Date()
            let hooks=TimelineLifecycle<ForbiddenProducer>.Hooks(shouldCapture:{_ in fatalError("Unexpected capture predicate")},onRecord:{_ in fatalError("Unexpected native record")},onSuppressedRecord:{_ in fatalError("Unexpected native suppressed record")},prepareStorage:resources.prepareStorage,prepareMemory:resources.prepareMemory,
                resetRecentApplications:recent.reset,cancelPendingRecords:{processor?.cancelPendingRecords()},processCompletedSegment:{_ in fatalError("Unexpected completed segment")},recordEvent:{_ in},
                scheduleResume:{_,_ in Task{@MainActor in try?await ContinuousClock().sleep(for:.seconds(3600))}},onError:{_ in})
            let owner=TimelineLifecycle(coordinator:EventStreamCaptureCoordinator(recorder:ForbiddenProducer()),store:TimelineSegmentStore(rootDirectoryURL:eventRoot),rootURL:eventRoot,defaults:defaults,hooks:hooks,now:{now})
            let classifier=TimelineRecordClassifier(settings:settings.get,resolver:EventStreamApplicationResolver(),filter:ForbiddenURLFilter())
            processor=TimelineRecordProcessor(writer:{[weak owner] in owner?.segmentWriter},classifier:classifier,recent:recent,onCompletedSegment:{_ in fatalError("Unexpected rotation")},onError:{_ in})
            let observation=Observation()
            let token=NotificationCenter.default.addObserver(forName:nil,object:nil,queue:nil){notice in
                guard notice.name.rawValue.hasPrefix("timelineService")else{return}
                MainActor.assumeIsolated {observation.rows.append(["name":notice.name.rawValue,"objectMatches":(notice.object as AnyObject?)===owner,"status":try!encoded(owner.status())])}
            }
            defer{NotificationCenter.default.removeObserver(token)}
            for (stepIndex,step)in (row["steps"]as![[String:Any]]).enumerated() {
                let op=step["operation"]as![String:Any],kind=op["kind"]as!String,status=step["statusAfter"]as![String:Any]
                let before=step["beforeOperationUnixTime"]as!Double,after=step["afterOperationUnixTime"]as!Double
                now=Date(timeIntervalSince1970:before)
                if kind=="start",owner.state == .stopped,let date=status["startedAt"]as?Double{now=Date(timeIntervalSinceReferenceDate:date)}
                if kind=="stop",owner.state != .stopped,let date=status["endedAt"]as?Double{now=Date(timeIntervalSinceReferenceDate:date)}
                if kind=="start" || kind=="stop"{precondition(now.timeIntervalSince1970>=before-0.001 && now.timeIntervalSince1970<=after+0.001)}
                defaults.calls=[];observation.rows=[]
                let instructions=home.appendingPathComponent("memories/extensions/timeline/instructions.md"),oldAttributes=try?FileManager.default.attributesOfItem(atPath:instructions.path)
                var actual:[String:Any]=["operation":op]
                do {
                    switch kind {
                    case "start":actual["value"]=try encoded(owner.start())
                    case "pause":actual["value"]=try encoded(owner.pause())
                    case "stop":actual["value"]=try encoded(owner.stop(reason:.init(rawValue:UInt8(op["reason"]as!Int))!))
                    case "receive":
                        let record=step["decodedRecord"]as![String:Any]
                        actual["decodedRecord"]=record
                        processor.receive(try JSONDecoder().decode(EventStreamRecord.self,from:json(record)),isSuppressed:op["suppressed"]as?Bool ?? false);actual["value"]=NSNull()
                    case "drain":
                        let deadline=Date(timeIntervalSinceNow:2)
                        repeat{CFRunLoopRunInMode(.defaultMode,0.001,false);if processor.pendingCount==0 && processor.processingTask==nil{break}}while Date()<deadline
                        precondition(processor.pendingCount==0 && processor.processingTask==nil);actual["value"]=NSNull()
                    case "cancelRecords":processor.cancelPendingRecords();actual["value"]=NSNull()
                    case "closeMain":try owner.segmentWriter?.segmentFileHandle?.close();actual["value"]=NSNull()
                    case "openSuppressed":
                        let url=home.appendingPathComponent("suppressed-fixture.jsonl");try Data().write(to:url)
                        owner.segmentWriter?.suppressedFileHandle=try FileHandle(forWritingTo:url);actual["value"]=NSNull()
                    case "closeSuppressed":try owner.segmentWriter?.suppressedFileHandle?.close();actual["value"]=NSNull()
                    default:fatalError("Unsupported record fixture operation")
                    }
                }catch{actual["error"]=failure(error)}
                actual["statusAfter"]=try encoded(owner.status());actual["resumeTaskPresent"]=owner.hasScheduledResume
                actual["preferenceCalls"]=defaults.calls;actual["preferenceValues"]=defaults.values.mapValues(represent)
                actual["notifications"]=observation.rows;actual["filesystem"]=try snapshot(home)
                actual["pendingCount"]=processor.pendingCount;actual["recordTaskPresent"]=processor.processingTask != nil
                actual["writer"]=writerState(owner.segmentWriter);actual["recentEntries"]=recents(recent)
                let newAttributes=try?FileManager.default.attributesOfItem(atPath:instructions.path)
                if let oldAttributes{actual["instructionsFileUnchanged"]=(oldAttributes[.systemFileNumber]as?NSNumber)==(newAttributes?[.systemFileNumber]as?NSNumber) && (oldAttributes[.modificationDate]as?Date)==(newAttributes?[.modificationDate]as?Date)}
                else{actual["instructionsFileUnchanged"]=NSNull()}
                var expected=step;expected.removeValue(forKey:"beforeOperationUnixTime");expected.removeValue(forKey:"afterOperationUnixTime")
                if let error=expected["error"]as?[String:Any]{expected["error"]=comparableFailure(error)}
                let a=try json(normalized(actual,root:home.path)),e=try json(normalized(expected,root:expectedHome.path)),label="\(row["name"]!)/\(stepIndex)"
                if a==e{print("PASS: record queue \(label)");passed+=1}
                else{print("FAIL: \(label)\nexpected \(String(data:e,encoding:.utf8)!)\nactual \(String(data:a,encoding:.utf8)!)");failed+=1}
            }
        }
        print("\(passed) asynchronous record operations matched; \(failed) failed")
        try FileManager.default.removeItem(at:localRoot)
        exit(failed==0 ? 0:1)
    }
}

