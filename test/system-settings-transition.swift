import Foundation
import CoreGraphics

@main enum SystemSettingsTransitionTests {
    static func main() throws {
        let expected=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let cases=expected["cases"] as! [[String:Any]]
        func encode(_ value: CGFloat) -> String { value.isNaN ? "nan":value == .infinity ? "inf":value == -.infinity ? "-inf":String(Double(value)) }
        func fields(_ rect: CGRect) -> [String] { [rect.origin.x,rect.origin.y,rect.size.width,rect.size.height].map(encode) }
        var results=[[String:Any]]()
        for row in cases {
            let s=(row["source"] as! [String]).map { Double($0)! },t=(row["target"] as! [String]).map { Double($0)! }
            let source=CGRect(x:s[0],y:s[1],width:s[2],height:s[3]),target=CGRect(x:t[0],y:t[1],width:t[2],height:t[3])
            let actual=SystemSettingsTransitionGeometry.frame(from:source,to:target,progress:CGFloat(Double(row["progress"] as! String)!),lift:CGFloat(Double(row["lift"] as! String)!))
            let passed=fields(actual)==row["frame"] as! [String] && fields(actual.integral)==row["integral"] as! [String]
            print("\(passed ? "PASS":"FAIL") transition geometry \(row["name"]!)")
            results.append(["name":row["name"]!,"passed":passed,"actual":fields(actual),"integral":fields(actual.integral)])
        }
        let passed=results.allSatisfy { $0["passed"] as? Bool == true }
        if CommandLine.arguments.count > 2 {
            try JSONSerialization.data(withJSONObject:["passed":passed,"cases":cases.count,"results":results,"nativeUIExecuted":false],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
        }
        if !passed { exit(1) }
    }
}
