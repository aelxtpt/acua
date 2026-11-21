import Foundation

@MainActor private final class Replay {
    let model:SystemSettingsSpringAnimation
    var events=[[String:Any]](),reentrant:[String:String]?
    init(_ input:[String:Any]) {
        model = .init(initialValue:Double(input["initial"] as! String)!,targetValue:Double(input["target"] as! String)!,period:Double(input["period"] as! String)!,dampingFraction:Double(input["damping"] as! String)!,idleVelocityThreshold:(input["idleVelocityThreshold"] as? String).map { Double($0)! })
        reentrant=input["reentrant"] as? [String:String]
        enable(true)
    }
    func encode(_ d:Double)->String { d.isNaN ? "nan":d == .infinity ? "inf":d == -.infinity ? "-inf":String(d) }
    func snapshot()->[String:Any] {
        ["value":encode(model.value),"target":encode(model.targetValue),"state":model.state.rawValue,
         "startTime":model.startTime.map(encode) as Any? ?? NSNull(),"simulationTime":encode(model.simulation.time),
         "velocity":encode(model.simulation.velocity),"acceleration":encode(model.simulation.acceleration),"logicallyComplete":model.isLogicallyComplete]
    }
    func enable(_ enabled:Bool) {
        if enabled { model.eventHandler={ [weak self] event in self?.received(event) } }
        else { model.eventHandler=nil }
    }
    func received(_ event:SystemSettingsSpringAnimation.Event) {
        var row=snapshot();let tag:Int
        switch event {
        case .valueChanged(let old,let new):tag=0;row["first"]=encode(old);row["second"]=encode(new)
        case .finished(let value):tag=1;row["first"]=encode(value)
        case .targetChanged(let from,let to):tag=2;row["first"]=encode(from);row["second"]=encode(to)
        }
        row["tag"]=tag;events.append(row)
        if let operation=reentrant,operation["onTag"]==String(tag) { reentrant=nil;perform(operation) }
    }
    func perform(_ op:[String:String]) {
        switch op["kind"]! {
        case "tick":let time=Double(op["time"]!)!;model.performTick(.init(timestamp:time,duration:Double(op["duration"] ?? "0.016666666666666666")!,targetTimestamp:Double(op["targetTimestamp"] ?? String(time+1.0/60))!))
        case "target":model.targetValue=Double(op["value"]!)!
        case "stop":model.stop(immediately:op["immediately"] == "true")
        case "reset":model.reset()
        case "handler":enable(op["enabled"] == "true")
        default:preconditionFailure("unknown operation")
        }
    }
}
@main private enum Tests {
    @MainActor static func main() throws {
        let payload=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        var rows=[[String:Any]](),snapshots=0,eventCount=0
        for input in payload["cases"] as! [[String:Any]] {
            let replay=Replay(input);var actual=[replay.snapshot()]
            for operation in input["operations"] as! [[String:String]] { replay.perform(operation);actual.append(replay.snapshot()) }
            let expected=input["snapshots"] as! [[String:Any]],expectedEvents=input["events"] as! [[String:Any]]
            let stateMatch=NSArray(array:actual)==NSArray(array:expected),eventMatch=NSArray(array:replay.events)==NSArray(array:expectedEvents)
            let passed=stateMatch && eventMatch
            let name=(input["name"] as! String)+"-"+(input["valueType"] as! String)
            print("\(passed ? "PASS":"FAIL") \(name)")
            if !passed {
                if let i=actual.indices.first(where:{NSDictionary(dictionary:actual[$0]) != NSDictionary(dictionary:expected[$0])}) { print("state \(i): expected \(expected[i]) got \(actual[i])") }
                if !eventMatch { print("events: expected \(expectedEvents.count) got \(replay.events.count)");if let i=replay.events.indices.first(where:{$0<expectedEvents.count && NSDictionary(dictionary:replay.events[$0]) != NSDictionary(dictionary:expectedEvents[$0])}) { print("event \(i): expected \(expectedEvents[i]) got \(replay.events[i])") } }
            }
            snapshots += actual.count;eventCount += replay.events.count;rows.append(["name":name,"passed":passed,"statesMatch":stateMatch,"eventsMatch":eventMatch])
        }
        let passed=rows.allSatisfy { $0["passed"] as? Bool == true }
        let result:[String:Any] = ["passed":passed,"cases":rows.count,"snapshots":snapshots,"events":eventCount,"results":rows,"nativeWindowDriverOrUIExecuted":false]
        if CommandLine.arguments.count>2 { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2])) }
        if !passed { exit(1) }
    }
}
