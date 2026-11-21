import Foundation
import AVFoundation
import CoreMedia
import CoreAudio

struct PCMChunk {
    var frames:Int
    var rate:Double=24_000
    var channels:UInt32=2
    var format:AVAudioCommonFormat = .pcmFormatFloat32
    var interleaved=false
    var segmented=false
    var aligned=true
    var ready=true
    var pattern="ramp"
    var missingFormat=false
    var noData=false
    var invalidated=false
    var outputType=1
}
struct PCMCase {let name:String;let chunks:[PCMChunk];var whileStarting=false}
func pcmCases()->[PCMCase] {
    var values=[PCMCase]()
    for frames in [1,3,5,17,64,480]{values.append(PCMCase(name:"planar-\(frames)",chunks:[PCMChunk(frames:frames)]))}
    for frames in [3,17,480]{values.append(PCMCase(name:"segmented-\(frames)",chunks:[PCMChunk(frames:frames,segmented:true)]))}
    values += [
        PCMCase(name:"unaligned-planar-3",chunks:[PCMChunk(frames:3,aligned:false)]),
        PCMCase(name:"silence",chunks:[PCMChunk(frames:480,pattern:"silence")]),
        PCMCase(name:"clipping",chunks:[PCMChunk(frames:32,pattern:"clipping")]),
        PCMCase(name:"nonfinite",chunks:[PCMChunk(frames:16,pattern:"nonfinite")]),
        PCMCase(name:"split-3-5",chunks:[PCMChunk(frames:3),PCMChunk(frames:5)]),
        PCMCase(name:"mono",chunks:[PCMChunk(frames:32,channels:1)]),
        PCMCase(name:"three-channels",chunks:[PCMChunk(frames:32,channels:3)]),
        PCMCase(name:"rate-16000",chunks:[PCMChunk(frames:32,rate:16_000)]),
        PCMCase(name:"rate-48000",chunks:[PCMChunk(frames:32,rate:48_000)]),
        PCMCase(name:"interleaved",chunks:[PCMChunk(frames:32,interleaved:true)]),
        PCMCase(name:"int16-planar",chunks:[PCMChunk(frames:64,format:.pcmFormatInt16)]),
        PCMCase(name:"float64-planar",chunks:[PCMChunk(frames:32,format:.pcmFormatFloat64)]),
        PCMCase(name:"zero-frames",chunks:[PCMChunk(frames:0)]),
        PCMCase(name:"not-ready-with-data",chunks:[PCMChunk(frames:16,ready:false)]),
        PCMCase(name:"missing-format",chunks:[PCMChunk(frames:0,missingFormat:true)]),
        PCMCase(name:"no-data",chunks:[PCMChunk(frames:8,noData:true)]),
        PCMCase(name:"invalidated",chunks:[PCMChunk(frames:8,invalidated:true)]),
        PCMCase(name:"screen-output",chunks:[PCMChunk(frames:16,outputType:0)]),
        PCMCase(name:"unknown-output",chunks:[PCMChunk(frames:16,outputType:99)]),
        PCMCase(name:"rate-switch",chunks:[PCMChunk(frames:16),PCMChunk(frames:16,rate:48_000),PCMChunk(frames:16)]),
        PCMCase(name:"while-starting",chunks:[PCMChunk(frames:16),PCMChunk(frames:16)],whileStarting:true)
    ]
    return values
}
struct SyntheticInput {
    let sample:CMSampleBuffer
    let storage:[NSMutableData]
    let description:[String:Any]
}
private func sampleValue(_ frame:Int,_ channel:Int,_ pattern:String)->Float {
    if pattern=="silence"{return 0}
    let values:[Float]
    switch pattern {
    case "clipping":values=[-1.25,-1,-0.999969482421875,-0.1,0,0.1,0.999969482421875,1,1.25]
    case "nonfinite":values=[0,.nan,.infinity,-.infinity,0.5,-0.5,1,-1]
    default:values=[-0.75,-0.5,-0.25,-0.015625,0,0.015625,0.25,0.5,0.75]
    }
    return values[(frame*(channel+1)+channel)%values.count] * (channel==0 ? 1:0.5)
}
private func pcmStatus(_ status:OSStatus,_ step:String) -> Bool {
    if status != noErr {fputs("OWNED_PCM_BUILDER \(step): \(status)\n",stderr)}
    return status == noErr
}
func makePCM(_ spec:PCMChunk,position:Int64)->SyntheticInput {
    let format:AVAudioFormat
    if spec.channels>2 {
        let layout=AVAudioChannelLayout(layoutTag:kAudioChannelLayoutTag_DiscreteInOrder | spec.channels)!
        format=AVAudioFormat(commonFormat:spec.format,sampleRate:spec.rate,interleaved:spec.interleaved,channelLayout:layout)
    } else {
        format=AVAudioFormat(commonFormat:spec.format,sampleRate:spec.rate,channels:spec.channels,interleaved:spec.interleaved)!
    }
    let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:AVAudioFrameCount(max(1,spec.frames)))!
    pcm.frameLength=AVAudioFrameCount(spec.frames)
    let list=UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
    for buffer in 0..<list.count {
        let pointer=list[buffer].mData!,channels=spec.interleaved ? Int(spec.channels):1
        for frame in 0..<spec.frames {for part in 0..<channels {
            let value=sampleValue(frame, spec.interleaved ? part:buffer,spec.pattern),index=frame*channels+part
            switch spec.format {
            case .pcmFormatInt16:pointer.assumingMemoryBound(to:Int16.self)[index]=Int16(max(-32768,min(32767,Int(value*32768))))
            case .pcmFormatFloat64:pointer.assumingMemoryBound(to:Double.self)[index]=Double(value)
            default:pointer.assumingMemoryBound(to:Float.self)[index]=value
            }
        }}
    }
    var description:CMAudioFormatDescription?
    precondition(pcmStatus(CMAudioFormatDescriptionCreate(allocator:kCFAllocatorDefault,asbd:format.streamDescription,layoutSize:0,layout:nil,magicCookieSize:0,magicCookie:nil,extensions:nil,formatDescriptionOut:&description),"format-description"))
    var storage=[NSMutableData](),block:CMBlockBuffer?
    if spec.segmented {
        precondition(CMBlockBufferCreateEmpty(allocator:kCFAllocatorDefault,capacity:UInt32(list.count),flags:0,blockBufferOut:&block)==noErr)
        for buffer in list {
            let data=NSMutableData(bytes:buffer.mData!,length:Int(buffer.mDataByteSize));storage.append(data)
            precondition(CMBlockBufferAppendMemoryBlock(block!,memoryBlock:data.mutableBytes,length:data.length,blockAllocator:kCFAllocatorNull,customBlockSource:nil,offsetToData:0,dataLength:data.length,flags:0)==noErr)
        }
    }
    var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:Int32(spec.rate)),presentationTimeStamp:CMTime(value:position,timescale:Int32(spec.rate)),decodeTimeStamp:.invalid)
    var sample:CMSampleBuffer?
    precondition(pcmStatus(CMSampleBufferCreate(allocator:kCFAllocatorDefault,dataBuffer:block,dataReady:spec.segmented || spec.frames==0,makeDataReadyCallback:nil,refcon:nil,formatDescription:spec.missingFormat ? nil:description,sampleCount:spec.frames,sampleTimingEntryCount:spec.frames==0 ? 0:1,sampleTimingArray:&timing,sampleSizeEntryCount:0,sampleSizeArray:nil,sampleBufferOut:&sample),"sample-buffer"))
    if !spec.segmented && spec.frames>0 && !spec.noData {
        precondition(pcmStatus(CMSampleBufferSetDataBufferFromAudioBufferList(sample!,blockBufferAllocator:kCFAllocatorDefault,blockBufferMemoryAllocator:kCFAllocatorDefault,flags:spec.aligned ? UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment):0,bufferList:pcm.audioBufferList),"audio-buffer-list"))
        if spec.ready{precondition(CMSampleBufferSetDataReady(sample!)==noErr)}
    }
    if spec.invalidated{precondition(CMSampleBufferInvalidate(sample!)==noErr)}
    let info:[String:Any]=["frames":spec.frames,"rate":spec.rate,"channels":spec.channels,"format":spec.format.rawValue,"interleaved":spec.interleaved,"segmented":spec.segmented,"aligned":spec.aligned,"ready":spec.ready,"missingFormat":spec.missingFormat,"noData":spec.noData,"invalidated":spec.invalidated,"outputType":spec.outputType]
    return SyntheticInput(sample:sample!,storage:storage,description:info)
}
func pcmWave(_ url:URL)->[String:Any] {
    var info=waveInfo(url)
    guard let data=try? Data(contentsOf:url),data.count>=12 else{return info}
    let bytes=[UInt8](data)
    func size(_ i:Int)->Int{(0..<4).reduce(0){$0 | Int(bytes[i+$1]) << (8*$1)}}
    var cursor=12
    while cursor+8<=bytes.count {
        let tag=String(bytes:bytes[cursor..<cursor+4],encoding:.ascii),length=size(cursor+4),start=cursor+8
        if tag=="data",length<=bytes.count-start {
            let pcm=Array(bytes[start..<start+length])
            info["pcmHex"]=pcm.map{String(format:"%02x",$0)}.joined()
            info["samples"] = stride(from:0,to:pcm.count-1,by:2).map{Int(Int16(bitPattern:UInt16(pcm[$0]) | UInt16(pcm[$0+1]) << 8))}
            break
        }
        guard length<=bytes.count-start else{break}
        cursor=start+length+(length%2)
    }
    return info
}
