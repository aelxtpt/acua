import Foundation
import SwiftUI

@main struct TextChecks {
    static func record(_ value:AttributedString)->[String:Any] {
        ["text":String(value.characters),"runs":value.runs.map { run in
            ["text":String(value[run.range].characters),"color":run.foregroundColor == .primary ? "primary" : run.foregroundColor == .secondary ? "secondary" : "other"]
        }]
    }
    static func main() throws {
        let rows=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [[String:Any]]
        for row in rows {
            let actual:Any
            if row["kind"] as! String == "label" {
                actual=SettingsAccessoryInstruction.permissionLabel(.init(paneID:row["pane"] as! String,anchor:row["anchor"] as? String)).map(record) ?? NSNull()
            } else {
                actual=record(SettingsAccessoryInstruction.text(applicationName:row["name"] as! String,destination:nil))
            }
            let a=try JSONSerialization.data(withJSONObject:actual,options:[.fragmentsAllowed,.sortedKeys])
            let b=try JSONSerialization.data(withJSONObject:row["result"]!,options:[.fragmentsAllowed,.sortedKeys])
            precondition(a==b,"text/color mismatch: \(row)")
            print("PASS text and attributed runs \(row["kind"]!)")
        }
        let result:[String:Any]=["passed":true,"cases":rows.count,"permissionObjectsConstructed":false,"nativeUIRenderingInputCaptureExecuted":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
    }
}
