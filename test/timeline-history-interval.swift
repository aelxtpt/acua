import Foundation
@main enum Tests {
    static func main()throws {
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let rows=(reference["payload"] as! [String:Any])["rows"] as! [[String:Any]]
        for row in rows {
            var calendar=Calendar(identifier:.gregorian);calendar.timeZone=TimeZone(identifier:row["zone"] as! String)!
            let now=Date(timeIntervalSinceReferenceDate:row["now"] as! Double)
            let interval=DateInterval(start:Date(timeIntervalSinceReferenceDate:row["start"] as! Double),end:Date(timeIntervalSinceReferenceDate:row["end"] as! Double))
            let scopes:[TimelineValidatedHistoryScope]=[.applicationSession(interval),.interval(interval),.lastTenMinutes,.lastHour,.lastDay,.all]
            let actual=scopes[row["kind"] as! Int].resolvedInterval(now:now,calendar:calendar),expected=row["value"] as! [String:Double]
            guard actual.start.timeIntervalSinceReferenceDate==expected["start"],actual.end.timeIntervalSinceReferenceDate==expected["end"] else{fatalError("Interval difference \(row): \(actual)")}
            print("PASS: Timeline history interval \(row["name"]!)")
        }
        print("\(rows.count) corpus Timeline history interval checks passed; production component")
    }
}
