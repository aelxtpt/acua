import Foundation

private func materialize(_ item:[String:Any],root:URL)throws {
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    for path in item["directories"] as? [String] ?? [] {try FileManager.default.createDirectory(at:root.appendingPathComponent(path,isDirectory:true),withIntermediateDirectories:true)}
    for (path,contents) in item["files"] as? [String:String] ?? [:] {
        let url=root.appendingPathComponent(path);try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try Data(contents.replacingOccurrences(of:"$ROOT",with:root.path).utf8).write(to:url)
    }
}
private func snapshot(_ root:URL)throws->[String:Any] {
    var directories=[String](),files=[String:String]()
    if let enumerator=FileManager.default.enumerator(at:root,includingPropertiesForKeys:[.isDirectoryKey]) {
        for case let url as URL in enumerator {
            guard url.path.hasPrefix(root.path+"/") else {
                fputs("Fixture path mismatch: root=\(root.path), entry=\(url.path)\n",stderr)
                fatalError("Fixture enumeration escaped its root")
            }
            let path=String(url.path.dropFirst(root.path.count+1))
            if (try url.resourceValues(forKeys:[.isDirectoryKey])).isDirectory==true {directories.append(path)}
            else {files[path]=(try String(contentsOf:url,encoding:.utf8)).replacingOccurrences(of:root.path,with:"$ROOT")}
        }
    }
    return ["directories":directories.sorted(),"files":files]
}
private func errorValue(_ error:Error)->[String:Any] {
    switch error {
    case DecodingError.keyNotFound(let key,let c):return ["kind":"keyNotFound","path":c.codingPath.map(\.stringValue),"key":key.stringValue]
    case DecodingError.typeMismatch(_,let c):return ["kind":"typeMismatch","path":c.codingPath.map(\.stringValue)]
    case DecodingError.valueNotFound(_,let c):return ["kind":"valueNotFound","path":c.codingPath.map(\.stringValue)]
    case DecodingError.dataCorrupted(let c):return ["kind":"dataCorrupted","path":c.codingPath.map(\.stringValue)]
    default:let native=error as NSError;return ["domain":native.domain,"code":native.code]
    }
}
@main enum Tests {
    static func main()throws {
        let corpus=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let rows=(corpus["payload"] as! [String:Any])["rows"] as! [[String:Any]]
        let base=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("cua-timeline-store-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:base)}
        var failures=[String]()
        for (index,row) in rows.enumerated() {
            let item=row["input"] as! [String:Any],root=base.appendingPathComponent(String(index),isDirectory:true)
            try materialize(item,root:root)
            let store=TimelineSegmentStore(rootDirectoryURL:root,segmentDurationSeconds:item["duration"] as? Double ?? 600)
            let now=Date(timeIntervalSince1970:item["now"] as! Double)
            var actual=[String:Any](),expected=[String:Any]()
            for key in ["value","error","filesystem"] {if let value=row[key]{expected[key]=value}}
            do {
                switch item["operation"] as! String {
                case "list":actual["value"]=try store.segmentDirectories().map{String($0.path.dropFirst(root.path.count+1))}.sorted()
                case "latest":
                    if let value=try store.latestCompletedSegment(now:now) {
                        let encoder=JSONEncoder();encoder.outputFormatting = .withoutEscapingSlashes
                        let text=String(decoding:try encoder.encode(value),as:UTF8.self).replacingOccurrences(of:root.path,with:"$ROOT")
                        actual["value"]=try JSONSerialization.jsonObject(with:Data(text.utf8))
                    }else{actual["value"]=NSNull()}
                case "contains","remove":
                    let interval=DateInterval(start:Date(timeIntervalSince1970:item["start"] as! Double),end:Date(timeIntervalSince1970:item["end"] as! Double))
                    if item["operation"] as! String=="contains" {actual["value"]=try store.containsSegments(overlapping:interval)}
                    else {actual["value"]=try store.removeSegments(overlapping:interval).map{["start":$0.start.timeIntervalSince1970,"end":$0.end.timeIntervalSince1970]}.sorted{$0["start"]!<$1["start"]!}}
                case "prune":
                    try store.prune(now:now,keeping:(item["keep"] as? [String] ?? []).map{root.appendingPathComponent($0,isDirectory:true)})
                    actual["value"]=NSNull()
                default:fatalError("Unknown corpus operation")
                }
            }catch {actual["error"]=errorValue(error)}
            actual["filesystem"]=try snapshot(root)
            if (actual as NSDictionary).isEqual(to:expected){print("PASS: Timeline segment store \(row["name"]!)")}
            else {failures.append(row["name"] as! String);print("FAIL: \(row["name"]!): actual=\(actual), expected=\(expected)")}
        }
        guard failures.isEmpty else{fatalError("Segment store differences: \(failures)")}
        print("\(rows.count) corpus filesystem checks passed")
    }
}
