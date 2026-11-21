import Foundation
import ObjectiveC
import ScreenCaptureKit
import Darwin
import CoreMedia

final class Locked<Value>: @unchecked Sendable {
    private let lock=NSLock();private var stored:Value
    init(_ value:Value){stored=value}
    func get()->Value{lock.lock();defer{lock.unlock()};return stored}
    func edit(_ operation:(inout Value)->Void){lock.lock();operation(&stored);lock.unlock()}
}
typealias NativeCallback = @convention(block)(NSError?)->Void
final class NativeOwnedStream:NSObject,@unchecked Sendable {
    let addFailure:Bool,stopFailure:Bool,configuration:[String:Any]
    let outputURL:URL
    let starts=Locked(0),stops=Locked(0),adds=Locked(0)
    let outputTypes=Locked([Int]()),queuePresent=Locked([Bool]())
    private let callback=Locked<NativeCallback?>(nil)
    weak var output:AnyObject?
    private var deliveryQueue:DispatchQueue?
    func emit(_ sample:CMSampleBuffer,type:Int=1)->Bool {
        guard let output else{return false}
        let selector=NSSelectorFromString("stream:didOutputSampleBuffer:ofType:")
        let method=class_getInstanceMethod(object_getClass(output),selector)!
        typealias Delivery=@convention(c)(AnyObject,Selector,AnyObject,CMSampleBuffer,Int)->Void
        let call=unsafeBitCast(method_getImplementation(method),to:Delivery.self)
        guard let queue=deliveryQueue else{preconditionFailure("Missing owned delivery queue")}
        queue.sync{call(output,selector,self,sample,type)}
        return true
    }
    init(addFailure:Bool,stopFailure:Bool,configuration:[String:Any],outputURL:URL) {
        self.outputURL=outputURL
        self.addFailure=addFailure;self.stopFailure=stopFailure;self.configuration=configuration
    }
    @objc(addStreamOutput:type:sampleHandlerQueue:error:)
    func add(_ output:AnyObject,type:Int,queue:AnyObject?,error:AutoreleasingUnsafeMutablePointer<NSError?>?)->Bool {
        self.output=output;self.deliveryQueue=queue as? DispatchQueue;adds.edit{$0 += 1};outputTypes.edit{$0.append(type)};queuePresent.edit{$0.append(queue != nil)}
        if addFailure {error?.pointee=NSError(domain:"OwnedNativeAdd",code:44);return false}
        return true
    }
    @objc(startCaptureWithCompletionHandler:)
    func start(_ handler:@escaping NativeCallback) {
        callback.edit{$0=handler};starts.edit{$0 += 1}
    }
    @objc(stopCaptureWithCompletionHandler:)
    func stop(_ handler:@escaping NativeCallback) {
        stops.edit{$0 += 1};handler(stopFailure ? NSError(domain:"OwnedNativeStop",code:46):nil)
    }
    func releaseStart(failure:Bool) {
        var handler:NativeCallback?;callback.edit{handler=$0;$0=nil}
        precondition(handler != nil);handler?(failure ? NSError(domain:"OwnedNativeStart",code:45):nil)
    }
}
final class NativeFixture:@unchecked Sendable {
    static let shared=NativeFixture()
    let streams=Locked([NativeOwnedStream]()),queryFlags=Locked([[Bool]]())
    let options=Locked((add:false,stop:false)),allocatedReceivers=Locked([UInt]())
    let holdQuery=Locked(false),heldQueries=Locked([()->Void]())
    func releaseQuery() {
        var reply:(()->Void)?;heldQueries.edit{precondition(!$0.isEmpty);reply=$0.removeFirst()}
        holdQuery.edit{$0=false};reply?()
    }
    var display:AnyObject!
    var directory:NSURL!
    func construct(_ config:SCStreamConfiguration)->NativeOwnedStream {
        let options=options.get()
        let known=Set(streams.get().map{$0.outputURL})
        let files=try! FileManager.default.contentsOfDirectory(at:directory as URL,includingPropertiesForKeys:nil)
        let output=files.first{$0.pathExtension=="wav" && !known.contains($0)}!
        let stream=NativeOwnedStream(addFailure:options.add,stopFailure:options.stop,configuration:["capturesAudio":config.capturesAudio,"excludesCurrentProcessAudio":config.excludesCurrentProcessAudio,"sampleRate":config.sampleRate,"channelCount":config.channelCount],outputURL:output)
        streams.edit{$0.append(stream)};return stream
    }
}
private final class OwnedContent:NSObject {
    @objc var displays:[AnyObject]{[NativeFixture.shared.display!]}
}
private final class OwnedFilter:NSObject {}
private typealias QueryCallback=@convention(block)(AnyObject?,NSError?)->Void
private typealias QueryIMP=@convention(c)(AnyObject,Selector,Bool,Bool,@escaping QueryCallback)->Void
private typealias FilterIMP=@convention(c)(UnsafeMutableRawPointer,Selector,UnsafeRawPointer,UnsafeRawPointer)->UnsafeMutableRawPointer
private typealias StreamIMP=@convention(c)(UnsafeMutableRawPointer,Selector,UnsafeRawPointer,UnsafeRawPointer,UnsafeRawPointer?)->UnsafeMutableRawPointer
private typealias TempIMP=@convention(c)(AnyObject,Selector)->Unmanaged<NSURL>
private let queryStub:QueryIMP={_,_,excluding,onScreen,handler in
    let fixture=NativeFixture.shared
    fixture.queryFlags.edit{$0.append([excluding,onScreen])}
    let reply={handler(OwnedContent(),nil)}
    if fixture.holdQuery.get(){fixture.heldQueries.edit{$0.append(reply)}}else{reply()}
}
private let filterStub:FilterIMP={receiver,_,_,_ in
    NativeFixture.shared.allocatedReceivers.edit{$0.append(UInt(bitPattern:receiver))}
    return Unmanaged.passRetained(OwnedFilter()).toOpaque()
}
private let streamStub:StreamIMP={receiver,_,_,configuration,_ in
    NativeFixture.shared.allocatedReceivers.edit{$0.append(UInt(bitPattern:receiver))}
    let config=Unmanaged<AnyObject>.fromOpaque(configuration).takeUnretainedValue() as! SCStreamConfiguration
    return Unmanaged.passRetained(NativeFixture.shared.construct(config)).toOpaque()
}
private let tempStub:TempIMP={_,_ in Unmanaged.passUnretained(NativeFixture.shared.directory)}
func nativeMethod(_ index:Int)->Method {
    switch index {
    case 0:return class_getInstanceMethod(SCStream.self,NSSelectorFromString("startCaptureWithCompletionHandler:"))!
    case 1:return class_getInstanceMethod(SCStream.self,NSSelectorFromString("stopCaptureWithCompletionHandler:"))!
    case 2:return class_getClassMethod(SCShareableContent.self,NSSelectorFromString("getShareableContentExcludingDesktopWindows:onScreenWindowsOnly:completionHandler:"))!
    case 3:return class_getInstanceMethod(SCContentFilter.self,NSSelectorFromString("initWithDisplay:excludingWindows:"))!
    case 4:return class_getInstanceMethod(SCStream.self,NSSelectorFromString("initWithFilter:configuration:delegate:"))!
    default:return class_getInstanceMethod(SCStream.self,NSSelectorFromString("addStreamOutput:type:sampleHandlerQueue:error:"))!
    }
}
@_cdecl("cua_audio_guard_implementation")
public func guardImplementation(_ which:Int32)->UInt {UInt(bitPattern:method_getImplementation(nativeMethod(Int(which))))}
func installNativeFixture(_ directory:URL)->()->Void {
    let fixture=NativeFixture.shared
    typealias Create=@convention(c)(AnyClass,Int)->UnsafeMutableRawPointer
    let create=unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern:-2),"class_createInstance")!,to:Create.self)
    // The zeroed display supplies only class identity for array bridging. It is
    // never initialized, queried or released into SDK destruction; this owned
    // test process reclaims its allocation at exit.
    fixture.display=Unmanaged<AnyObject>.fromOpaque(create(SCDisplay.self,0)).takeUnretainedValue()
    fixture.directory=directory as NSURL
    let tempMethod=class_getInstanceMethod(FileManager.self,NSSelectorFromString("temporaryDirectory"))!
    let methods=[nativeMethod(2),nativeMethod(3),nativeMethod(4),tempMethod]
    let originals=methods.map{method_getImplementation($0)}
    let replacements=[unsafeBitCast(queryStub,to:IMP.self),unsafeBitCast(filterStub,to:IMP.self),unsafeBitCast(streamStub,to:IMP.self),unsafeBitCast(tempStub,to:IMP.self)]
    for (method,implementation) in zip(methods,replacements){method_setImplementation(method,implementation)}
    precondition(FileManager.default.temporaryDirectory.standardizedFileURL==directory.standardizedFileURL)
    return {for (method,implementation) in zip(methods,originals){method_setImplementation(method,implementation)}}
}
func nativeError(_ error:Error)->[String:Any] { ["error":String(describing:error),"domain":(error as NSError).domain,"code":(error as NSError).code] }
func waveInfo(_ url:URL)->[String:Any] {
    guard let data=try? Data(contentsOf:url),data.count>=12 else{return ["missing":true]}
    let bytes=[UInt8](data)
    func text(_ i:Int,_ n:Int)->String{String(bytes:bytes[i..<(i+n)],encoding:.ascii) ?? "?"}
    func number(_ i:Int,_ n:Int)->Int{(0..<n).reduce(0){$0 | Int(bytes[i+$1]) << (8*$1)}}
    guard text(0,4)=="RIFF",text(8,4)=="WAVE" else{return ["invalid":true]}
    var result:[String:Any]=["container":"RIFF/WAVE"],cursor=12
    while cursor+8<=bytes.count {
        let name=text(cursor,4),size=number(cursor+4,4),offset=cursor+8
        if name=="fmt ",size>=16,offset+16<=bytes.count {
            result["formatTag"]=number(offset,2);result["channels"]=number(offset+2,2)
            result["sampleRate"]=number(offset+4,4);result["byteRate"]=number(offset+8,4)
            result["blockAlign"]=number(offset+12,2);result["bitsPerSample"]=number(offset+14,2)
        }
        if name=="data" {result["dataBytes"]=size;break}
        if size>bytes.count-offset {break}
        cursor=offset+size+(size%2)
    }
    return result
}
