import Foundation
@main enum Tests {
    static func main()throws {
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let rows=(reference["payload"] as! [String:Any])["rows"] as! [[String:Any]]
        for row in rows {
            let rule=try JSONDecoder().decode(TimelineObservationRule.self,from:JSONSerialization.data(withJSONObject:row["rule"]!))
            let input=row["input"] as? String,value:Bool
            switch row["kind"] as! String {
            case "app":value=rule.matchesApplication(bundleIdentifier:input)
            case "url":value=rule.matches(url:input)
            default:value=rule.matches(host:input!)
            }
            guard value==row["value"] as! Bool else{fatalError("Matching difference \(row): \(value)")}
            print("PASS: Timeline matching \(row["name"]!)")
        }
        print("\(rows.count) corpus Timeline matching checks passed; production component")
    }
}
