import Foundation
@main enum Tests {
    static func main()throws {
        let corpus=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let rows=(corpus["payload"] as! [String:Any])["rows"] as! [[String:Any]]
        let base=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("cua-timeline-writer-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:base)}
        var failures=[String]()
        for (i,row) in rows.enumerated() {
            let item=row["input"] as! [String:Any],root=base.appendingPathComponent(String(i),isDirectory:true)
            try writerMaterialize(item,root:root)
            var actual=[String:Any](),expected=[String:Any]()
            for key in ["state","error","filesystem"] {if let value=row[key]{expected[key]=value}}
            do {
                let writer=try TimelineSegmentWriter(store:.init(rootDirectoryURL:root,segmentDurationSeconds:item["duration"] as! Double),now:Date(timeIntervalSince1970:item["now"] as! Double))
                let state=writer.currentSegment
                actual["state"]=["id":state.id,"eventsPath":state.eventsURL.path.replacingOccurrences(of:root.path,with:"$ROOT"),"metadataPath":state.metadataURL.path.replacingOccurrences(of:root.path,with:"$ROOT"),"startedAt":state.startedAt.timeIntervalSince1970,"eventCount":state.eventCount.map{$0 as Any} ?? NSNull(),"suppressedEventCount":state.suppressedEventCount.map{$0 as Any} ?? NSNull(),"suppressedEventsPath":writer.suppressedEventsURL.map{$0.path.replacingOccurrences(of:root.path,with:"$ROOT") as Any} ?? NSNull(),"eventHandleOpen":writer.segmentFileHandle != nil,"suppressedHandleOpen":writer.suppressedFileHandle != nil]
                writer.close()
            }catch {let error=error as NSError;actual["error"]=["domain":error.domain,"code":error.code]}
            actual["filesystem"]=try writerSnapshot(root)
            if (actual as NSDictionary).isEqual(to:expected) {print("PASS: Timeline writer initialization \(row["name"]!)")}
            else{failures.append(row["name"] as! String);print("FAIL: \(row["name"]!): actual=\(actual), expected=\(expected)")}
        }
        guard failures.isEmpty else{fatalError("Writer initialization differences: \(failures)")}
        print("\(rows.count) corpus writer initialization checks passed; component comparison")
    }
}
