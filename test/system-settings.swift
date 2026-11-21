import Foundation

@main enum SystemSettingsTests {
    static func main() throws {
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String:Any]
        var results = [[String:Any]]()
        func check(_ value: Bool, _ name: String) { results.append(["name":name,"passed":value]); print("\(value ? "PASS":"FAIL") system settings \(name)") }
        let cases = expected["cases"] as! [[String:Any]]
        for row in cases {
            let destination = SystemSettings.Destination(paneID:row["paneID"] as! String,anchor:row["anchor"] as? String)
            var observed = row
            do { observed["url"] = try SystemSettings.url(for:destination).absoluteString;observed["outcome"]="url" }
            catch {
                let error=error as NSError
                observed["outcome"]="error";observed["domain"]=error.domain;observed["code"]=error.code
                observed["description"]=error.localizedDescription;observed["userInfoKeys"]=error.userInfo.keys.sorted()
            }
            check(NSDictionary(dictionary:row).isEqual(to:observed),"URL pair \(row["name"]!)")
        }
        let defaults:[String:SystemSettings.Destination] = ["notifications":.notifications,"privacy":.privacy,
            "privacyFullDiskAccess":.privacyFullDiskAccess,"privacyAccessibility":.privacyAccessibility,
            "privacyScreenCapture":.privacyScreenCapture,"privacyLocation":.privacyLocation,
            "privacyContacts":.privacyContacts,"privacyCalendar":.privacyCalendar,"privacyReminders":.privacyReminders,
            "privacyAppleEvents":.privacyAppleEvents,"privacyCamera":.privacyCamera]
        let expectedDefaults=expected["defaults"] as! [[String:Any]]
        check(expectedDefaults.allSatisfy { row in
            guard let value=defaults[row["name"] as! String] else{return false}
            return value.paneID == row["paneID"] as! String && value.anchor == row["anchor"] as? String
        } && expectedDefaults.count == defaults.count,"eleven immutable destination constants")
        let absent=SystemSettings.Destination(paneID:"owned"), empty=SystemSettings.Destination(paneID:"owned",anchor:"")
        check(absent != empty && Set([absent,empty]).count == 2,"nil and empty anchor remain distinct in value identity")
        let encoder=JSONEncoder(), decoder=JSONDecoder()
        check(try decoder.decode(SystemSettings.Destination.self,from:encoder.encode(absent)) == absent &&
              decoder.decode(SystemSettings.Destination.self,from:encoder.encode(empty)) == empty,"destination Codable round trips preserve nil versus empty")
        let passed=results.allSatisfy{$0["passed"] as? Bool == true}
        let record:[String:Any]=["passed":passed,"cases":results.count,"results":results,
            "expectedURLPairs":cases.count,"destinationConstants":11,"nativeSettingsOrPermissionProviderExecuted":false]
        try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        if !passed { exit(1) }
    }
}
