import Foundation

@main private enum Tests {
    static func main() throws {
        let input=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        func number(_ d:Double)->String { d.isNaN ? "nan":d == .infinity ? "inf":d == -.infinity ? "-inf":String(d) }
        var rows=[[String:Any]](),snapshots=0
        for row in input["cases"] as! [[String:Any]] {
            func field(_ name:String)->Double { Double(row[name] as! String)! }
            let config=SystemSettingsScalarSpring.Configuration(period:field("period"),dampingFraction:field("damping"),tolerance:(row["tolerance"] as? String).map { Double($0)! } ?? 0.06)
            var spring=SystemSettingsScalarSpring(configuration:config,value:field("value"),target:field("target"),time:field("time"),velocity:field("velocity"),acceleration:field("acceleration"))
            let actualConfig=[config.period,config.stiffness,config.damping,config.timeStep,config.tolerance].map(number)
            let expectedConfig=row["configuration"] as! [String]
            var differences=[String]()
            if actualConfig != expectedConfig { differences.append("configuration expected \(expectedConfig) got \(actualConfig)") }
            let expected=row["snapshots"] as! [[String:Any]],operations=row["operations"] as! [[String:String]]
            func compare(_ i:Int) {
                snapshots += 1
                let actual=["value":number(spring.value),"time":number(spring.time),"velocity":number(spring.velocity),"acceleration":number(spring.acceleration)]
                for (key,value) in actual where expected[i][key] as? String != value {
                    differences.append("snapshot \(i) \(key) expected \(expected[i][key]!) got \(value)")
                }
                if expected[i]["complete"] as? Bool != spring.isComplete { differences.append("snapshot \(i) complete expected \(expected[i]["complete"]!) got \(spring.isComplete)") }
            }
            compare(0)
            for (i,operation) in operations.enumerated() {
                switch operation["kind"]! {
                case "step":spring.step()
                case "advance":spring.advance(to:Double(operation["time"]!)!)
                case "retarget":spring.target=Double(operation["target"]!)!
                case "reset":spring.reset()
                default:preconditionFailure("unknown operation")
                }
                compare(i+1)
            }
            let passed=differences.isEmpty
            print("\(passed ? "PASS":"FAIL") \(row["name"]!)\(passed ? "":" "+differences.prefix(3).joined(separator:"; "))")
            rows.append(["name":row["name"]!,"passed":passed,"differences":differences])
        }
        let passed=rows.allSatisfy { $0["passed"] as? Bool == true }
        let output:[String:Any] = ["passed":passed,"cases":rows.count,"snapshots":snapshots,"results":rows,"simulationPairs":rows.count,"nativeUIExecuted":false]
        if CommandLine.arguments.count>2 { try JSONSerialization.data(withJSONObject:output,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:CommandLine.arguments[2])) }
        if !passed { exit(1) }
    }
}
