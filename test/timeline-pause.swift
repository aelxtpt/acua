import Foundation
@main enum Tests {
    static func main()throws {
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let rows=(reference["payload"] as! [String:Any])["rows"] as! [[String:Any]]
        for row in rows {
            var calendar=Calendar(identifier:row["calendar"] as! String=="hebrew" ? .hebrew:row["calendar"] as! String=="islamic" ? .islamic:.gregorian)
            calendar.timeZone=TimeZone(identifier:row["zone"] as! String)!
            let kind:[TimelinePauseDuration]=[.thirtyMinutes,.oneHour,.untilTomorrow]
            let now=Date(timeIntervalSinceReferenceDate:row["now"] as! Double)
            let actual=kind[row["kind"] as! Int].resumeDate(now:now,calendar:calendar).timeIntervalSinceReferenceDate
            guard actual==row["value"] as! Double else{fatalError("Pause difference \(row): \(actual)")}
            print("PASS: Timeline pause \(row["name"]!)")
        }
        print("\(rows.count) corpus Timeline pause checks passed; production component")
    }
}
