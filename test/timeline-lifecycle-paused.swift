import Foundation

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

@main private enum Main {
    @MainActor static func main()throws {
        let path=URL(fileURLWithPath:CommandLine.arguments[1])
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:path))as![String:Any]
        let rows=(reference["payload"]as![String:Any])["rows"]as![[String:Any]]
        let nativeRoot=URL(fileURLWithPath:reference["fixture_directory"]as!String).appendingPathComponent("fixtures",isDirectory:true)
        let template=reference["instructionsTemplate"]as!String
        let localRoot=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("cua-paused-comparison-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:localRoot,withIntermediateDirectories:true)
        defer{try?FileManager.default.removeItem(at:localRoot)}
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        var passed=0,failed=0,eventCount=0,ids=Set<UUID>()
        for (rowIndex,row) in rows.enumerated() {
            let home=localRoot.appendingPathComponent(String(rowIndex),isDirectory:true),expectedHome=nativeRoot.appendingPathComponent(String(rowIndex),isDirectory:true)
            try FileManager.default.createDirectory(at:home,withIntermediateDirectories:true)
            let input=row["input"]as![String:Any]
            if let initial=input["fixture"]as?[String:Any]{try fixture(initial,home:home)}
            let defaults=MemoryDefaults()
            if let date=input["initialDate"]as?Double{defaults.values["timeline.pauseResumeDate"]=Date(timeIntervalSince1970:date)}
            let eventRoot=home.appendingPathComponent("eventstream",isDirectory:true)
            let resources=TimelineResourcePreparation(eventStreamRootURL:eventRoot,configurationRootURL:home.appendingPathComponent("timeline",isDirectory:true),memoryExtensionURL:home.appendingPathComponent("memories/extensions/timeline",isDirectory:true),loadInstructions:{template})
            var now=Date(),telemetry=[[String:Any]](),nativeTelemetry=[[String:Any]](),emitted=0
            let hooks=TimelineLifecycle<ForbiddenProducer>.Hooks(
                shouldCapture:{_ in fatalError("Unexpected predicate")},onRecord:{_ in fatalError("Unexpected record")},onSuppressedRecord:{_ in fatalError("Unexpected suppressed record")},
                prepareStorage:resources.prepareStorage,prepareMemory:resources.prepareMemory,
                resetRecentApplications:{},cancelPendingRecords:{},processCompletedSegment:{_ in fatalError("Unexpected completed segment")},
                recordEvent:{event in
                    precondition(emitted<nativeTelemetry.count,"Unexpected lifecycle event")
                    let recorded=nativeTelemetry[emitted]
                    telemetry.append(AgentStructuredTelemetry.envelope(parameters:TimelineLifecycleTelemetry.parameters(event:event),id:UUID(uuidString:recorded["eventId"]as!String)!,createdAt:formatter.date(from:recorded["eventCreatedAt"]as!String)!))
                    emitted+=1
                },scheduleResume:{_,_ in Task{@MainActor in fatalError("Future scheduled task executed inside synchronous fixture")}},onError:{_ in})
            let owner=TimelineLifecycle(coordinator:EventStreamCaptureCoordinator(recorder:ForbiddenProducer()),store:TimelineSegmentStore(rootDirectoryURL:eventRoot),rootURL:eventRoot,defaults:defaults,hooks:hooks,now:{now})
            let observation=Observation()
            let token=NotificationCenter.default.addObserver(forName:nil,object:nil,queue:nil){notice in
                guard notice.name.rawValue.hasPrefix("timelineService")else{return}
                MainActor.assumeIsolated {
                    observation.rows.append(["name":notice.name.rawValue,"objectMatches":(notice.object as AnyObject?)===owner,"telemetryCount":telemetry.count,"status":try!encoded(owner.status())])
                }
            }
            defer{NotificationCenter.default.removeObserver(token)}
            for (stepIndex,step) in (row["steps"]as![[String:Any]]).enumerated() {
                let op=step["operation"]as![String:Any],kind=op["kind"]as!String
                let before=step["beforeOperationUnixTime"]as!Double,after=step["afterOperationUnixTime"]as!Double
                let nativeStatus=step["statusAfter"]as![String:Any]
                now=Date(timeIntervalSince1970:before)
                if kind=="start",owner.state == .stopped,let date=nativeStatus["startedAt"]as?Double{
                    now=Date(timeIntervalSinceReferenceDate:date)
                    precondition(now.timeIntervalSince1970>=before-0.001 && now.timeIntervalSince1970<=after+0.001)
                }
                if kind=="stop",owner.state != .stopped,let date=nativeStatus["endedAt"]as?Double{
                    now=Date(timeIntervalSinceReferenceDate:date)
                    precondition(now.timeIntervalSince1970>=before-0.001 && now.timeIntervalSince1970<=after+0.001)
                }
                if kind=="pauseFor",let duration=op["duration"]as?Int,duration<2 {
                    let values=step["preferenceValues"]as![String:Any],date=(values["timeline.pauseResumeDate"]as![String:Any])["dateUnix"]as!Double
                    now=Date(timeIntervalSince1970:date-(duration==0 ? 1800:3600))
                    precondition(now.timeIntervalSince1970>=before-0.001 && now.timeIntervalSince1970<=after+0.001)
                }
                nativeTelemetry=step["telemetry"]as![[String:Any]];telemetry=[];emitted=0;observation.rows=[];defaults.calls=[]
                for event in nativeTelemetry {
                    let id=UUID(uuidString:event["eventId"]as!String)!,created=formatter.date(from:event["eventCreatedAt"]as!String)!.timeIntervalSince1970
                    precondition(id.uuidString==event["eventId"]as!String && ids.insert(id).inserted && created>=before-0.001 && created<=after+0.001)
                    eventCount+=1
                }
                let instructions=home.appendingPathComponent("memories/extensions/timeline/instructions.md")
                let oldAttributes=try?FileManager.default.attributesOfItem(atPath:instructions.path)
                var actual:[String:Any]=["operation":op]
                do {
                    switch kind {
                    case "start":actual["value"]=try encoded(owner.start())
                    case "status":actual["value"]=try encoded(owner.status())
                    case "pause":actual["value"]=try encoded(owner.pause())
                    case "pauseFor":actual["value"]=try encoded(owner.pause(for:[TimelinePauseDuration.thirtyMinutes,.oneHour,.untilTomorrow][op["duration"]as!Int]))
                    case "getDate":actual["value"]=owner.pauseResumeDate.map{$0.timeIntervalSince1970} ?? NSNull()
                    case "stop":actual["value"]=try encoded(owner.stop(reason:.init(rawValue:UInt8(op["reason"]as!Int))!))
                    case "fixture":try fixture(op,home:home);actual["value"]=NSNull()
                    default:fatalError("Unknown operation")
                    }
                }catch{actual["error"]=failure(error)}
                actual["statusAfter"]=try encoded(owner.status());actual["resumeTaskPresent"]=owner.hasScheduledResume
                actual["preferenceCalls"]=defaults.calls;actual["preferenceValues"]=defaults.values.mapValues(represent)
                actual["notifications"]=observation.rows;actual["telemetry"]=telemetry;actual["filesystem"]=try snapshot(home)
                let newAttributes=try?FileManager.default.attributesOfItem(atPath:instructions.path)
                if let oldAttributes{actual["instructionsFileUnchanged"]=(oldAttributes[.systemFileNumber]as?NSNumber)==(newAttributes?[.systemFileNumber]as?NSNumber) && (oldAttributes[.modificationDate]as?Date)==(newAttributes?[.modificationDate]as?Date)}
                else{actual["instructionsFileUnchanged"]=NSNull()}
                var expected=step;expected.removeValue(forKey:"beforeOperationUnixTime");expected.removeValue(forKey:"afterOperationUnixTime")
                if let error=expected["error"]as?[String:Any]{expected["error"]=comparableFailure(error)}
                let a=try json(normalized(actual,root:home.path)),e=try json(normalized(expected,root:expectedHome.path))
                let label="\(row["name"]!)/\(stepIndex)"
                if a==e{print("PASS: paused lifecycle \(label)");passed+=1}
                else{print("FAIL: \(label)\nexpected \(String(data:e,encoding:.utf8)!)\nactual \(String(data:a,encoding:.utf8)!)");failed+=1}
            }
        }
        print("\(passed) paused-owner operation comparisons; \(eventCount) complete envelopes; \(failed) failures")
        try FileManager.default.removeItem(at:localRoot)
        exit(failed==0 ? 0:1)
    }
}
