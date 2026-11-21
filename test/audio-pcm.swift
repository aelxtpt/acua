// Expected PCM sample bytes for owned fake buffers; no system audio.
import Foundation
import ScreenCaptureKit

private let owned=AudioRecorder.Owner(sessionID:"owned-session",senderPID:123,turnID:"owned-turn")
private func url(_ recorder:AudioRecorder)->URL? {
    let record=Mirror(reflecting:recorder).children.first{$0.label=="recording"}!.value
    return Mirror(reflecting:record).children.first.flatMap { element in
        Mirror(reflecting:element.value).children.first{$0.label=="url"}?.value as? URL
    }
}
private func start(_ recorder:AudioRecorder)->[String:Any] {
    do {try recorder.start(.init(maxDurationMilliseconds:300_000),owner:owned);return ["ok":true]}
    catch {return nativeError(error)}
}
private func stop(_ recorder:AudioRecorder)->[String:Any] {
    do {let value=try recorder.stop(owner:owned);return ["ok":true,"url":value.path]}
    catch {return nativeError(error)}
}
private func wait(_ predicate:()->Bool) {
    let limit=ProcessInfo.processInfo.systemUptime+3
    while !predicate() {
        precondition(ProcessInfo.processInfo.systemUptime<limit,"Owned sample test timed out")
        Thread.sleep(forTimeInterval:0.002)
    }
}
private func run(_ directory:URL,_ selected:[String]?)->[String:Any] {
    let fixture=NativeFixture.shared;var rows=[[String:Any]]()
    for item in pcmCases() where selected==nil || selected!.contains(item.name) {
        fputs("ACUA_PCM_CASE \(item.name)\n",stderr)
        let index=fixture.streams.get().count,recorder=AudioRecorder(),started=Locked<[String:Any]?>(nil)
        DispatchQueue.global().async{let value=start(recorder);started.edit{$0=value}}
        wait{fixture.streams.get().count>index}
        let stream=fixture.streams.get()[index];wait{stream.starts.get()==1}
        let target=url(recorder)!
        if !item.whileStarting{stream.releaseStart(failure:false);wait{started.get() != nil}}
        var inputs=[[String:Any]](),delivered=[Bool](),position:Int64=0,claimed:[String:Any]?
        for (part,spec) in item.chunks.enumerated() {
            let input=makePCM(spec,position:position);position += Int64(spec.frames)
            inputs.append(input.description);delivered.append(stream.emit(input.sample,type:spec.outputType))
            withExtendedLifetime(input){}
            if item.whileStarting && part==0 {claimed=stop(recorder)}
        }
        if item.whileStarting{stream.releaseStart(failure:false);wait{started.get() != nil}}
        let claim=claimed ?? stop(recorder)
        Thread.sleep(forTimeInterval:0.05)
        rows.append(["name":item.name,"start":started.get()!,"claim":claim,"delivered":delivered,"inputs":inputs,"wave":pcmWave(target),"starts":stream.starts.get(),"stops":stream.stops.get(),"ownedURL":target.path])
    }
    return ["cases":rows,"complete":true,"realAudioRecordings":0,"sampleSource":"owned synthetic PCM"]
}
@main struct Main {
    static func main() throws {
        let arguments=CommandLine.arguments
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("cua-owned-pcm-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let restore=installNativeFixture(directory);defer{restore()}
        let result=Locked<[String:Any]?>(nil)
        DispatchQueue.global().async{let value=run(directory,nil);result.edit{$0=value}}
        let limit=Date().addingTimeInterval(35)
        while result.get()==nil && Date()<limit{_ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.002))}
        guard let value=result.get() else{fatalError("Owned PCM batch timed out")}
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:arguments[1]))
        if arguments.count>2 {
            let expected=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:arguments[2]))) as! [String:Any]
            let keys=expected["comparedFields"] as! [String]
            let expectedRows=expected["cases"] as! [[String:Any]],actualRows=value["cases"] as! [[String:Any]]
            precondition(actualRows.count==expectedRows.count,"PCM case count differs")
            for (actual,expected) in zip(actualRows,expectedRows) {
                let filtered=Dictionary(uniqueKeysWithValues:keys.map{($0,actual[$0]!)})
                precondition((filtered as NSDictionary).isEqual(to:expected),"PCM differs from the expected case: \(actual["name"]!)")
                print("PASS PCM \(actual["name"]!)")
            }
        }
    }
}
