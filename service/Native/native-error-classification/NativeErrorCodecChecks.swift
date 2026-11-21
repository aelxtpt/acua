import Foundation

struct ControllerNativeErrorFixture:Codable,Sendable {
    let name:String
    let code:Int32
    let payload:String
    let description:String
}
struct ControllerNativeErrorFixtures:Decodable {let cases:[ControllerNativeErrorFixture]}
enum NativeErrorCodecChecks {
    static func run(output:URL,fixtures:URL)throws->Int32 {
        let values=try JSONDecoder().decode(ControllerNativeErrorFixtures.self,from:Data(contentsOf:fixtures)).cases
        let checks=values.map{v in ["name":v.name,"passed":ControllerNativeClientErrorCodec.describe(code:v.code,payload:v.payload)==v.description] as [String:Any]}
        let passed=checks.allSatisfy{$0["passed"] as? Bool==true}
        let report:[String:Any]=["passed":passed,"checks":checks,"actual_input_capture_focus_or_general_clipboard":false,"full_goal_complete":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native client error codec: \(checks.filter{$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
}
