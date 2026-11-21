import Foundation
@main enum Tests {
    static func main()throws {
        let reference=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let rows=(reference["payload"] as! [String:Any])["rows"] as! [[String:Any]]
        for row in rows {
            let request=try JSONDecoder().decode(TimelineClearHistoryRequest.self,from:JSONSerialization.data(withJSONObject:row["request"]!))
            do {_ = try request.validatedScope();fatalError("Invalid history request accepted")}
            catch {
                let native=error as NSError,expected=row["error"] as! [String:Any]
                let actual:[String:Any]=["domain":native.domain,"code":native.code,"message":native.localizedDescription,"reflected":String(reflecting:error),"userInfo":native.userInfo]
                guard (actual as NSDictionary).isEqual(to:expected)else{fatalError("History rejection difference: \(actual) != \(expected)")}
            }
            print("PASS: Timeline history rejection \(row["name"]!)")
        }
        print("\(rows.count) corpus Timeline history rejection checks passed; production component")
    }
}
