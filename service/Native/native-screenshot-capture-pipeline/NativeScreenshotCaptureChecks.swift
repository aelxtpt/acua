import AppKit
import Foundation

@MainActor enum NativeScreenshotCaptureChecks {
    static func run(output: URL) async throws -> Int32 {
        let parent=output.deletingLastPathComponent()
        let core=try await ScreenshotCaptureChecks.run(output:parent.appendingPathComponent("core-result.json"))
        guard core==0 else { return core }
        let native=try ScreenshotCaptureNativeChecks.run(output:parent.appendingPathComponent("configuration-result.json"))
        guard native==0 else { return native }
        var checks:[[String:Any]]=[]
        for failure in [ControllerScreenshotCaptureError.screenCaptureFailed,.invalidCaptureSize(.init(width:0,height:1))] {
            let raw=String(describing:failure)
            let mapped=ControllerNativeMappedError.classify(failure),xpc=ComputerUseXPC.requestError(failure)
            checks.append(["name":"screenshot failure reaches both raw and client-formatted transport conversions: "+raw,
                "passed":mapped.code == .unknownError && mapped.payload==raw && mapped.socketDescription=="Computer Use server error -10005: "+raw && xpc.code == -10005 && xpc.localizedDescription==raw])
        }
        let passed=checks.allSatisfy {$0["passed"] as? Bool==true}
        try JSONSerialization.data(withJSONObject:["passed":passed,"checks":checks,
            "actual_native_configuration_generated_raster_and_transport_conversion":true,
            "actual_screen_capture_or_input":false,"full_goal_complete":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native screenshot capture adapter errors: \(checks.filter {$0["passed"] as? Bool==true}.count)/\(checks.count)")
        return passed ? 0:3
    }
}
