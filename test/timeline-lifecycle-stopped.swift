import Foundation

private final class FixtureDefaults:UserDefaults,@unchecked Sendable {
    var values:[String:Any]=[:]
    var calls:[[String:Any]]=[]
    override func object(forKey key:String)->Any?{calls.append(["kind":"get","key":key]);return values[key]}
    override func set(_ value:Any?,forKey key:String){calls.append(["kind":"set","key":key]);values[key]=value}
    override func removeObject(forKey key:String){calls.append(["kind":"remove","key":key]);values.removeValue(forKey:key)}
}
private final class ForbiddenProducer:EventStreamCaptureProducing {
    typealias Application=String
    var isRecording:Bool{fatalError("Stopped owner touched producer")}
    var onRecordStored:((EventStreamRecord)->Void)?
    var onSuppressedRecordStored:((EventStreamRecord)->Void)?
    var shouldCaptureApplication:((String)->Bool)?
    func start()throws{fatalError("Stopped owner started capture")}
    func stop(emitSessionEnded:Bool){fatalError("Stopped owner stopped capture")}
    func refreshCurrentApplication(){fatalError("Stopped owner refreshed capture")}
    func flushPendingRecords(){fatalError("Stopped owner flushed capture")}
    func makeSessionBoundaryRecord(kind:EventStreamEventKind)->EventStreamRecord{fatalError("Stopped owner emitted record")}
}
private final class FixtureNotifications:@unchecked Sendable {var names=[String]()}
private func json(_ value:Any)throws->Data{try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys,.fragmentsAllowed])}
private func encoded(_ value:TimelineStatus)throws->Any{try JSONSerialization.jsonObject(with:JSONEncoder().encode(value))}
private func normalizedFailure(_ value:[String:Any])->[String:Any] {
    if (value["domain"]as?String)?.contains("TimelineError")==true {
        return ["kind":"TimelineError","code":value["code"]!,"reflected":value["reflected"]!,"userInfo":value["userInfo"]!]
    }
    return value
}
private func failure(_ error:Error)->[String:Any] {
    let value=error as NSError
    return normalizedFailure(["domain":value.domain,"code":value.code,"reflected":String(reflecting:error),"description":value.localizedDescription,"userInfo":value.userInfo])
}
private func represent(_ value:Any)->Any{if let date=value as?Date{return ["dateUnix":date.timeIntervalSince1970]};return value}

@main private enum Main {
    @MainActor static func main()throws {
        let result=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))as![String:Any]
        let rows=(result["payload"]as![String:Any])["rows"]as![[String:Any]]
        var passed=0,failed=0
        for row in rows {
            let input=row["input"]as![String:Any],defaults=FixtureDefaults()
            let key="timeline.pauseResumeDate"
            if let date=input["initialDate"]as?Double{defaults.values[key]=Date(timeIntervalSince1970:date)}
            if let raw=input["initialRaw"]{defaults.values[key]=raw}
            let hooks=TimelineLifecycle<ForbiddenProducer>.Hooks(
                shouldCapture:{_ in fatalError("Unexpected app predicate")},onRecord:{_ in fatalError("Unexpected record")},
                onSuppressedRecord:{_ in fatalError("Unexpected suppressed record")},
                prepareStorage:{fatalError("Missing storage did not fail first")},prepareMemory:{fatalError("Unexpected memory preparation")},
                resetRecentApplications:{fatalError("Unexpected recent reset")},cancelPendingRecords:{fatalError("Unexpected pending-record cancellation")},
                processCompletedSegment:{_ in fatalError("Unexpected memory processing")},recordEvent:{_ in fatalError("Unexpected telemetry")},
                scheduleResume:{_,_ in fatalError("Unexpected scheduling")},onError:{_ in fatalError("Unexpected swallowed error")})
            let owner=TimelineLifecycle(coordinator:EventStreamCaptureCoordinator(recorder:ForbiddenProducer()),store:nil,rootURL:nil,defaults:defaults,hooks:hooks)
            let notifications=FixtureNotifications()
            let token=NotificationCenter.default.addObserver(forName:nil,object:nil,queue:nil){notification in
                if notification.name.rawValue.hasPrefix("timelineService"){notifications.names.append(notification.name.rawValue)}
            }
            defer{NotificationCenter.default.removeObserver(token)}
            for (index,reference) in (row["steps"]as![[String:Any]]).enumerated() {
                defaults.calls=[];notifications.names=[]
                let operation=reference["operation"]as![String:Any]
                var actual:[String:Any]=["operation":operation]
                do {
                    switch operation["kind"]as!String {
                    case "getDate":actual["value"]=owner.pauseResumeDate.map{$0.timeIntervalSince1970} ?? NSNull()
                    case "setDate":owner.pauseResumeDate=(operation["date"]as?Double).map{Date(timeIntervalSince1970:$0)};actual["value"]=NSNull()
                    case "status":actual["value"]=try encoded(owner.status())
                    case "pause":actual["value"]=try encoded(owner.pause())
                    case "resume":actual["value"]=try encoded(owner.resume())
                    case "pauseFor":actual["value"]=try encoded(owner.pause(for:[TimelinePauseDuration.thirtyMinutes,.oneHour,.untilTomorrow][operation["duration"]as!Int]))
                    case "stop":actual["value"]=try encoded(owner.stop(reason:.init(rawValue:UInt8(operation["reason"]as!Int))!))
                    case "start":actual["value"]=try encoded(owner.start())
                    default:fatalError("Unsupported fixture operation")
                    }
                }catch{actual["error"]=failure(error)}
                actual["preferenceCalls"]=defaults.calls;actual["preferenceValues"]=defaults.values.mapValues(represent)
                actual["notifications"]=notifications.names;actual["statusAfter"]=try encoded(owner.status())
                var expected=reference
                if let error=expected["error"]as?[String:Any]{expected["error"]=normalizedFailure(error)}
                let label="\(row["name"]!)/\(index)"
                if try json(actual)==json(expected){print("PASS: stopped lifecycle \(label)");passed+=1}
                else {print("FAIL: \(label)\nexpected \(String(data:try json(expected),encoding:.utf8)!)\nactual \(String(data:try json(actual),encoding:.utf8)!)");failed+=1}
            }
        }
        print("\(passed) stopped-owner operations matched; \(failed) failed. Active native owner and IPC are not validated.")
        exit(failed==0 ? 0:1)
    }
}
