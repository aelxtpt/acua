import Foundation
private func failure(_ error:Error)->[String:Any] {
    var name="other",path=[String](),key:String?
    switch error {
    case DecodingError.keyNotFound(let k,let c):name="keyNotFound";path=c.codingPath.map(\.stringValue);key=k.stringValue
    case DecodingError.typeMismatch(_,let c):name="typeMismatch";path=c.codingPath.map(\.stringValue)
    case DecodingError.valueNotFound(_,let c):name="valueNotFound";path=c.codingPath.map(\.stringValue)
    case DecodingError.dataCorrupted(let c):name="dataCorrupted";path=c.codingPath.map(\.stringValue)
    default:break
    }
    var row:[String:Any]=["error":name,"path":path];if let key{row["key"]=key};return row
}
@main enum Tests {
    static func main()throws {
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let rows=(reference["payload"] as! [String:Any])["rows"] as! [[String:Any]]
        let types:[String:any Codable.Type]=["behavior":TimelineObservationDefaultBehavior.self,"scope":TimelineObservationRuleScope.self,"rule":TimelineObservationRule.self,"observation":TimelineObservationSettings.self,"settings":TimelineSettings.self,"state":TimelineState.self,"status":TimelineStatus.self,"start":TimelineStartRequest.self,"statusRequest":TimelineStatusRequest.self,"stop":TimelineStopRequest.self,"pause":TimelinePauseRequest.self,"duration":TimelinePauseDuration.self,"resume":TimelineResumeRequest.self,"getSettings":TimelineGetSettingsRequest.self,"updateSettings":TimelineUpdateSettingsRequest.self,"updatePolicy":TimelineUpdateObservationPolicyRequest.self,"clearScope":TimelineClearHistoryScope.self,"interval":TimelineHistoryInterval.self,"clearHistory":TimelineClearHistoryRequest.self]
        var checks=0
        for row in rows {
            let type=types[row["type"] as! String]!,input=Data((row["input"] as! String).utf8)
            var expected=[String:Any](),actual=[String:Any]()
            for key in ["value","error","path","key","encodingError"] {if let value=row[key]{expected[key]=value}}
            do {
                let value=try JSONDecoder().decode(type,from:input)
                actual["value"]=try JSONSerialization.jsonObject(with:JSONEncoder().encode(value),options:[.fragmentsAllowed])
            }catch {actual=failure(error)}
            guard (actual as NSDictionary).isEqual(to:expected)else{fatalError("Mismatch \(row["type"]!) \(row["name"]!): \(actual) != \(expected)")}
            checks+=1;print("PASS: Timeline \(row["type"]!) \(row["name"]!)")
        }
        for row in (reference["payload"] as! [String:Any])["normalization"] as? [[String:Any]] ?? [] {
            let settings=try JSONDecoder().decode(TimelineObservationSettings.self,from:JSONSerialization.data(withJSONObject:row["settings"]!))
            do {
                let actual=try JSONSerialization.jsonObject(with:JSONEncoder().encode(settings.normalized())) as! NSDictionary
                guard let expected=row["value"] as? [String:Any],actual.isEqual(to:expected)else{fatalError("Normalization value \(row["name"]!)")}
            }catch {
                guard let expected=row["error"] as? [String:Any]else{throw error}
                let native=error as NSError
                guard native.code==expected["code"] as! Int,String(reflecting:error)==expected["reflected"] as! String,native.userInfo.isEmpty else{fatalError("Normalization error \(row["name"]!): \(error)")}
                // A private enum's NSError domain embeds a runtime context
                // address, so domain and message are recorded, not compared.
            }
            checks+=1;print("PASS: Timeline normalization \(row["name"]!)")
        }
        print("\(checks) corpus Timeline wire checks passed; production component")
    }
}
