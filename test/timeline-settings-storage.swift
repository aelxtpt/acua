import Foundation
@main enum Tests {
    static func main()throws {
        let corpus=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1])))as![String:Any]
        let rows=(corpus["payload"]as![String:Any])["rows"]as![[String:Any]]
        let base=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("cua-timeline-settings-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:base)}
        var count=0,failures=[String]()
        for(i,row)in rows.enumerated(){
            let home=base.appendingPathComponent(String(i),isDirectory:true),root=home.appendingPathComponent("timeline",isDirectory:true),item=row["input"]as![String:Any]
            try writerMaterialize(item,root:home);var cache=TimelineSettingsCache(configurationRootURL:root)
            for(k,step)in(row["steps"]as![[String:Any]]).enumerated(){
                let op=step["operation"]as![String:Any],kind=op["kind"]as!String
                var actual=[String:Any](),expected=[String:Any]()
                for key in ["value","error","filesystem"]{if let value=step[key]{expected[key]=value}}
                do{
                    switch kind{
                    case "get":actual["value"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(cache.get()))
                    case "reload":cache=TimelineSettingsCache(configurationRootURL:root);actual["value"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(cache.get()))
                    case "fixture":try writerMaterialize(op,root:home);actual["value"]=NSNull()
                    case "persist":let settings=try JSONDecoder().decode(TimelineSettings.self,from:JSONSerialization.data(withJSONObject:op["settings"]!));try TimelineSettingsStorage.write(settings,configurationRootURL:root);actual["value"]=NSNull()
                    default:fatalError("Unknown owned fixture operation")
                    }
                }catch{let e=error as NSError;actual["error"]=["domain":e.domain,"code":e.code]}
                actual["filesystem"]=try writerSnapshot(home)
                if(actual as NSDictionary).isEqual(to:expected){count+=1;print("PASS: settings storage \(row["name"]!)/\(k)")}
                else{failures.append("\(row["name"]!)/\(k)");print("FAIL: \(row["name"]!)/\(k) actual=\(actual) expected=\(expected)")}
            }
        }
        guard failures.isEmpty else{fatalError("Settings differences: \(failures)")}
        print("\(count) settings observations passed; production component")
    }
}
