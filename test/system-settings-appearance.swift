import Foundation

@main struct AppearanceChecks {
    static func encoded(_ x: Double) -> String { x.isNaN ? "nan" : x == .infinity ? "inf" : x == -.infinity ? "-inf" : String(x) }
    static func main() throws {
        let expected=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
        for row in expected {
            let look=SystemSettingsTransitionAppearance(progress:Double(row["progress"] as! String)!,hasSourceImage:row["source"] as! Bool,hasTargetImage:row["target"] as! Bool)
            let actual=["sourceOpacity":encoded(look.sourceOpacity),"targetOpacity":encoded(look.targetOpacity),"sourceBlur":encoded(look.sourceBlur),"targetBlur":encoded(look.targetBlur)]
            for (key,value) in actual { precondition(value == row[key] as! String,"\(row): \(key) got \(value)") }
            print("PASS appearance source=\(row["source"]!) target=\(row["target"]!) progress=\(row["progress"]!)")
        }
        let result:[String:Any]=["passed":true,"cases":expected.count,"comparedScalarValues":expected.count*4]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
    }
}
