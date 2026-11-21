import Foundation
private enum Expected: Error { case operation }
@main enum Tests {
    static func main() async throws {
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let wire = corpus["wire"] as! [String: Any]
        var checks = 0
        func check(_ label: String, _ condition: Bool) { precondition(condition,label); checks += 1; print("PASS: \(label)") }
        func object(_ data: Data?) throws -> Any { try data.map { try JSONSerialization.jsonObject(with: $0) } ?? NSNull() }
        func same(_ a: Any, _ b: Any) -> Bool { (a as AnyObject).isEqual(b) }
        let dates: [(String,Date?,Date?)] = [("absent",nil,nil),("reference-epoch",Date(timeIntervalSinceReferenceDate:0),Date(timeIntervalSinceReferenceDate:12.25)),("unix-epoch",Date(timeIntervalSince1970:0),nil),("fractional",Date(timeIntervalSince1970:1704067200.125),Date(timeIntervalSince1970:1704067201.875)),("nan",Date(timeIntervalSinceReferenceDate:.nan),nil)]
        let expectedDates = wire["statusWireRows"] as! [[String:Any]]
        for (name,start,end) in dates {
            let value = EventStreamSessionStatus(isRecording:false,startedAt:start,endedAt:end,maxDurationSeconds:1800)
            var row:[String:Any] = ["name":name]
            do { row["value"] = try object(JSONEncoder().encode(value)) }
            catch EncodingError.invalidValue(_,let context) { row["error"]="invalidValue";row["codingPath"]=context.codingPath.map(\.stringValue) }
            check("status wire \(name)",same(row,expectedDates.first{$0["name"] as? String==name}!))
        }
        let samples:[(String,ComputerUseJSONRPCCodexTurnMetadata)] = [
            ("absent",.init()),("all-fields",.init(model:"owned-model",reasoningEffort:"owned-effort",sessionID:"owned-session",turnID:"owned-turn",turnStartedAtUnixMilliseconds:1704067200123,userInputRequestedDuringTurn:true)),
            ("empty-session",.init(sessionID:"")),("only-zero-timestamp",.init(turnStartedAtUnixMilliseconds:0)),("only-false-input",.init(userInputRequestedDuringTurn:false))]
        for (name,metadata) in samples {
            let value = try object(ComputerUseTelemetryContext.Snapshot(metadata).agentTurnMetadataData())
            let expected = (wire["telemetryRows"] as! [[String:Any]]).first{$0["name"] as? String==name}!
            check("telemetry serialization \(name)",same(value,expected["value"]!))
            if let rpc = wire["rpcMetadataRows"] as? [[String:Any]] {
                check("RPC metadata serialization \(name)",same(try object(JSONEncoder().encode(metadata)),rpc.first{$0["name"] as? String==name}!["value"]!))
            }
        }
        var rows=[[String:Any]]()
        func row(_ name:String)throws {rows.append(["name":name,"value":try object(ComputerUseTelemetryContext.snapshot().agentTurnMetadataData())])}
        try row("initial")
        let result = try await ComputerUseTelemetryContext.withAgentTurnMetadata(Data(#"{"model":"outer","session_id":"parent-session","turn_id":"parent-turn"}"#.utf8)) {
            try row("outer")
            for (name,input) in [("nil",Optional<Data>.none),("empty",Data("{}".utf8)),("array",Data("[]".utf8)),("malformed",Data("{bad".utf8)),("partial-child",Data(#"{"session_id":"child"}"#.utf8)),("unknown-camel",Data(#"{"sessionID":"ignored"}"#.utf8)),("false-only",Data(#"{"user_input_requested_during_turn":false}"#.utf8)),("empty-session",Data(#"{"session_id":""}"#.utf8)),("bad-field",Data(#"{"model":"discard","session_id":true}"#.utf8))] {
                try await ComputerUseTelemetryContext.withAgentTurnMetadata(input) { await Task.yield();try row(name) }
            }
            try row("outer-restored")
            do { let _:Int = try await ComputerUseTelemetryContext.withAgentTurnMetadata(Data(#"{"session_id":"throw-child"}"#.utf8)) { await Task.yield();throw Expected.operation } }
            catch Expected.operation { rows.append(["name":"operation-error","error":"expected"]) }
            try row("outer-after-error");return "scope-return 🙂"
        }
        rows.append(["name":"return-value","value":result]);try row("after-outer")
        let expectedRows = (corpus["scope"] as! [String:Any])["rows"] as! [[String:Any]]
        for (a,b) in zip(rows,expectedRows) {check("scope \(a["name"]!)",same(a,b))}
        check("scope row count",rows.count==expectedRows.count)
        for value in [#"{"session_id":true}"#,#"{"turn_started_at_unix_ms":"1"}"#,#"{"user_input_requested_during_turn":1}"#,"[]","true"] {
            do { _ = try ComputerUseTelemetryContext.validatedWireData(try JSONSerialization.jsonObject(with:Data(value.utf8),options:[.fragmentsAllowed]));preconditionFailure("Invalid outer metadata accepted") }
            catch { check("strict outer decoder rejects \(value)",true) }
        }
        let parent = ComputerUseTelemetryContext.Snapshot(.init(sessionID:"parent"))
        let inherited = ComputerUseTelemetryContext.$current.withValue(parent) { Task { ComputerUseTelemetryContext.snapshot().agentSessionID } }
        check("new task inherits the caller snapshot",await inherited.value=="parent")
        async let first:String? = ComputerUseTelemetryContext.withAgentTurnMetadata(Data(#"{"session_id":"first"}"#.utf8)) {await Task.yield();return ComputerUseTelemetryContext.snapshot().agentSessionID}
        async let second:String? = ComputerUseTelemetryContext.withAgentTurnMetadata(Data(#"{"session_id":"second"}"#.utf8)) {await Task.yield();return ComputerUseTelemetryContext.snapshot().agentSessionID}
        let pair = await(first,second)
        check("overlapping tasks retain independent metadata",pair.0=="first" && pair.1=="second")
        check("completed tasks do not leak into the caller",ComputerUseTelemetryContext.snapshot().isEmpty)
        let threadValue:String? = await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                ComputerUseTelemetryContext.$current.withValue(parent) {
                    Task { continuation.resume(returning: ComputerUseTelemetryContext.snapshot().agentSessionID) }
                }
            }
        }
        check("socket-style thread scope reaches its asynchronous task",threadValue=="parent")
        let detached = ComputerUseTelemetryContext.$current.withValue(parent) { Task.detached { ComputerUseTelemetryContext.snapshot().agentSessionID } }
        check("detached tasks do not inherit the request context",await detached.value==nil)
        let sync = ComputerUseTelemetryContext.withAgentTurnMetadata(Data(#"{"session_id":"synchronous"}"#.utf8)) { ComputerUseTelemetryContext.snapshot().agentSessionID }
        check("synchronous dispatch binds and restores request metadata",sync=="synchronous" && ComputerUseTelemetryContext.snapshot().isEmpty)
        print("\(checks) telemetry and recording wire checks passed")
    }
}
