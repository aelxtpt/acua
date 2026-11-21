import Foundation

@main enum TypedAppBodyTests {
    static func main() throws {
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [JSON]
        var results = [JSON]()
        for test in cases {
            let name = test["name"] as! String, expected = test["expected"] as! JSON
            let type = DirectRequestType(rawValue: test["type"] as! String)
            let data = Data((test["input"] as! String).utf8)
            var actual: JSON = [:]
            do {
                let value = try test["mode"] as? String == "socket"
                    ? XPCAppUsageBody.decodeSocket(data, for: type)!
                    : XPCAppUsageBody.decode(data, for: type)
                actual["outcome"] = "decoded"
                if expected["value"] != nil { actual["value"] = value }
            } catch DecodingError.keyNotFound(let key, let context) {
                actual = ["outcome": "keyNotFound", "key": key.stringValue, "path": context.codingPath.map(\.stringValue)]
            } catch DecodingError.typeMismatch(_, let context) {
                actual = ["outcome": "typeMismatch", "path": context.codingPath.map(\.stringValue)]
            } catch DecodingError.valueNotFound(_, let context) {
                actual = ["outcome": "valueNotFound", "path": context.codingPath.map(\.stringValue)]
            } catch DecodingError.dataCorrupted(let context) {
                actual = ["outcome": "dataCorrupted", "path": context.codingPath.map(\.stringValue)]
            }
            guard NSDictionary(dictionary: actual).isEqual(to: expected) else {
                fatalError("\(name): expected \(expected), received \(actual)")
            }
            results.append(["name": name, "result": actual])
            print("PASS typed app-body contract: \(name)")
        }
        if CommandLine.arguments.count > 2 {
            try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        print("ALL \(cases.count) TYPED APP-BODY CHECKS PASSED")
    }
}
