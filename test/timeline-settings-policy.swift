import Foundation
private final class Trace:@unchecked Sendable {var events=[String]();var notifications=[[String:Any]]()}
@main enum Tests {
    static func failure(_ error:Error)->[String:Any]{
        let native=error as NSError
        if error is TimelineError{return ["kind":"TimelineError","code":native.code,"reflected":String(reflecting:error),"userInfo":native.userInfo]}
        return ["domain":native.domain,"code":native.code]
    }
    static func json(_ settings:TimelineSettings)throws->Any{try JSONSerialization.jsonObject(with:JSONEncoder().encode(settings))}
    static func decode(_ value:Any)throws->TimelineSettings{try JSONDecoder().decode(TimelineSettings.self,from:JSONSerialization.data(withJSONObject:value))}
    static func main()throws {
        let corpus=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))as![String:Any]
        let rows=(corpus["payload"]as![String:Any])["rows"]as![[String:Any]]
        let base=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("cua-timeline-settings-policy-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:base)}
        var count=0,failures=[String](),successfulUpdates=0
        for(i,row)in rows.enumerated(){
            let home=base.appendingPathComponent(String(i),isDirectory:true),root=home.appendingPathComponent("timeline",isDirectory:true),item=row["input"]as![String:Any]
            try writerMaterialize(item,root:home)
            if let pair=item["classification"]as?[String:Any]{
                let old=try decode(pair["old"]!),new=try decode(pair["new"]!)
                let actual=TimelineObservationSettingsUpdateType.classify(old:old.observation,new:new.observation).rawValue
                let step=(row["steps"]as![[String:Any]])[0]
                if Int(actual)==step["value"]as!Int {count+=1;print("PASS: settings classifier \(row["name"]!)")}
                else{failures.append(row["name"]as!String);print("FAIL: classifier \(row["name"]!) actual=\(actual) expected=\(step["value"]!)")}
                continue
            }
            let trace=Trace()
            func makeCache()->TimelineSettingsCache {TimelineSettingsCache(configurationRootURL:root,effects:.init(refreshCapture:{trace.events.append("refresh")},recordUpdate:{_,_ in trace.events.append("telemetry")}))}
            var cache=makeCache()
            for(k,step)in(row["steps"]as![[String:Any]]).enumerated(){
                let op=step["operation"]as![String:Any],kind=op["kind"]as!String
                var actual=[String:Any](),expected=[String:Any]()
                for key in ["value","classification","error","notifications","filesystem"]{if let value=step[key]{expected[key]=value}}
                trace.events=[];trace.notifications=[]
                let observedCache=cache
                let token=NotificationCenter.default.addObserver(forName:TimelineSettingsCache.didChangeNotification,object:nil,queue:nil){notification in
                    trace.events.append("notify")
                    let objectMatches=notification.object.map{Unmanaged.passUnretained($0 as AnyObject).toOpaque()==Unmanaged.passUnretained(observedCache).toOpaque()} ?? false
                    trace.notifications.append(["name":notification.name.rawValue,"objectMatches":objectMatches,"settings":try! json(observedCache.get())])
                }
                defer{NotificationCenter.default.removeObserver(token)}
                do{
                    switch kind{
                    case "get":actual["value"]=try json(cache.get())
                    case "reload":cache=makeCache();actual["value"]=try json(cache.get())
                    case "fixture":try writerMaterialize(op,root:home);actual["value"]=NSNull()
                    case "policy-app","policy-url":
                        let old=cache.get(),observe=op["observe"]as!Bool,target=op["target"]as!String
                        let value=try kind=="policy-app" ? cache.updateObservationPolicy(observe,forApplication:target):cache.updateObservationPolicy(observe,forURLDomain:target)
                        actual["value"]=try json(value);actual["classification"]=TimelineObservationSettingsUpdateType.classify(old:old.observation,new:value.observation).rawValue;successfulUpdates+=1
                    case "update":let old=cache.get(),value=try cache.update(decode(op["settings"]!));actual["value"]=try json(value);actual["classification"]=TimelineObservationSettingsUpdateType.classify(old:old.observation,new:value.observation).rawValue;successfulUpdates+=1
                    default:fatalError("Unknown owned fixture operation")
                    }
                }catch{actual["error"]=failure(error)}
                actual["notifications"]=trace.notifications;actual["filesystem"]=try writerSnapshot(home)
                let successful=(kind=="update" || kind.hasPrefix("policy-")) && actual["error"]==nil
                let orderMatches=trace.events==(successful ? ["refresh","notify","telemetry"]:[])
                if(actual as NSDictionary).isEqual(to:expected) && orderMatches {count+=1;print("PASS: settings policy \(row["name"]!)/\(k)")}
                else{failures.append("\(row["name"]!)/\(k)");print("FAIL: update \(row["name"]!)/\(k) actual=\(actual) expected=\(expected) trace=\(trace.events)")}
            }
        }
        let hits=corpus["coordinator_refresh_and_typed_telemetry_calls"]as![Int]
        precondition(hits==[successfulUpdates,successfulUpdates],"Refresh and telemetry calls differ from the successful-update count")
        guard failures.isEmpty else{fatalError("Settings differences: \(failures)")}
        print("\(count) settings policy/classification observations passed; \(successfulUpdates) refresh and typed telemetry calls each; production component")
    }
}
