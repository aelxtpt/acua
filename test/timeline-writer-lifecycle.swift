import Foundation
private func state(_ writer:TimelineSegmentWriter,_ root:URL)->[String:Any] {
    let value=writer.currentSegment
    return ["id":value.id,"eventsPath":value.eventsURL.path.replacingOccurrences(of:root.path,with:"$ROOT"),"metadataPath":value.metadataURL.path.replacingOccurrences(of:root.path,with:"$ROOT"),"startedAt":value.startedAt.timeIntervalSince1970,"eventCount":value.eventCount.map{$0 as Any} ?? NSNull(),"suppressedEventCount":value.suppressedEventCount.map{$0 as Any} ?? NSNull(),"suppressedEventsPath":NSNull(),"eventHandleOpen":writer.segmentFileHandle != nil,"suppressedHandleOpen":writer.suppressedFileHandle != nil]
}
@main enum Tests {
    static func main()throws {
        let corpus=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]))) as! [String:Any]
        let rows=(corpus["payload"] as! [String:Any])["rows"] as! [[String:Any]]
        let base=URL(fileURLWithPath:"/private/tmp",isDirectory:true).appendingPathComponent("cua-timeline-lifecycle-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:base)}
        var checks=0,failures=[String]()
        for (i,row) in rows.enumerated() {
            let item=row["input"] as! [String:Any],root=base.appendingPathComponent(String(i),isDirectory:true)
            try writerMaterialize(item,root:root)
            let writer=try TimelineSegmentWriter(store:.init(rootDirectoryURL:root,segmentDurationSeconds:item["duration"] as! Double),now:Date(timeIntervalSince1970:item["now"] as! Double))
            defer{writer.close()}
            for (stepIndex,step) in (row["steps"] as! [[String:Any]]).enumerated() {
                let operation=step["operation"] as! [String:Any],kind=operation["kind"] as! String
                var actual=[String:Any](),expected=[String:Any]()
                for key in ["value","error","state","filesystem"] {if let value=step[key]{expected[key]=value}}
                do {
                    let result:EventStreamMetadata?
                    if kind=="metadata-directory" {
                        let url=writer.currentSegment.metadataURL
                        try FileManager.default.removeItem(at:url);try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true);result=nil
                    }else if kind=="rotate" {
                        result=try writer.rotateIfNeeded(at:Date(timeIntervalSince1970:operation["at"] as! Double))
                    }else {
                        let expectedValue=step["value"] as? [String:Any]
                        let nativeTime=expectedValue?["endedAt"] as? Double ?? step["beforeReferenceTime"] as! Double
                        if let expectedValue,let end=expectedValue["endedAt"] as? Double {
                            precondition(end>=step["beforeReferenceTime"] as! Double && end<=step["afterReferenceTime"] as! Double,"Finish time is outside its measured call interval")
                        }
                        result=writer.finish(now:Date(timeIntervalSinceReferenceDate:nativeTime))
                    }
                    if let result {
                        let encoder=JSONEncoder();encoder.outputFormatting = .withoutEscapingSlashes
                        let text=String(decoding:try encoder.encode(result),as:UTF8.self).replacingOccurrences(of:root.path,with:"$ROOT")
                        actual["value"]=try JSONSerialization.jsonObject(with:Data(text.utf8))
                    }else{actual["value"]=NSNull()}
                }catch {let error=error as NSError;actual["error"]=["domain":error.domain,"code":error.code]}
                actual["state"]=state(writer,root);actual["filesystem"]=try writerSnapshot(root)
                if (actual as NSDictionary).isEqual(to:expected){checks+=1;print("PASS: writer lifecycle \(row["name"]!)/\(stepIndex)")}
                else{failures.append("\(row["name"]!)/\(stepIndex)");print("FAIL: \(row["name"]!)/\(stepIndex): actual=\(actual), expected=\(expected)")}
            }
        }
        guard failures.isEmpty else{fatalError("Writer component differences: \(failures)")}
        print("\(checks) writer lifecycle observations passed (21 native calls and1 fixture setup); component comparison")
    }
}
