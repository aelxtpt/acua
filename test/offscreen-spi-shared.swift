import Foundation
import CoreGraphics
import Darwin

struct SPIInput:Codable {
    let name:String,connection:String,response:String
    let ids:[UInt32]
    let options:UInt32
    let rect:[Double]
}
private var active:SPIInput?
private var answer:CFArray?
private var calls=[[String:Any]]()
let ownedConnection:@convention(c)()->OpaquePointer? = {
    OpaquePointer(bitPattern:UInt(active!.connection,radix:16)!)
}
let ownedImages:@convention(c)(OpaquePointer?,UnsafePointer<UInt32>,Int32,UInt32,CGRect)->Unmanaged<CFArray>? = { connection,ids,count,options,rect in
    calls.append(["connection":String(UInt(bitPattern:connection),radix:16),"ids":Array(UnsafeBufferPointer(start:ids,count:Int(count))),"options":options,"rect": [rect.origin.x,rect.origin.y,rect.width,rect.height].map{String(Double($0).bitPattern,radix:16)}])
    return answer.map{Unmanaged.passUnretained($0)}
}
private func image(_ width:Int,_ height:Int)->CGImage {
    let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red:0.25,green:0.5,blue:0.75,alpha:1));context.fill(CGRect(x:0,y:0,width:width,height:height))
    return context.makeImage()!
}
func prepare(_ input:SPIInput) {
    active=input;calls=[]
    switch input.response {
    case "nil":answer=nil
    case "empty":answer=[] as CFArray
    case "one":answer=[image(2,1)] as CFArray
    case "two":answer=[image(2,1),image(3,2)] as CFArray
    default:answer=[image(2,1),"invalid" as NSString] as CFArray
    }
}
func rectangle(_ input:SPIInput)->CGRect {CGRect(x:input.rect[0],y:input.rect[1],width:input.rect[2],height:input.rect[3])}
func connectionBits<T>(_ value:T)->String {
    withUnsafeBytes(of:value){bytes in
        let number=bytes.prefix(8).enumerated().reduce(UInt64(0)){$0 | UInt64($1.element) << ($1.offset*8)}
        return String(number,radix:16)
    }
}
func summary(_ input:SPIInput,_ images:[CGImage]?,connectionBits:String)->[String:Any] {
    let values:[[String:Any]]=images?.map { image in
        guard CFGetTypeID(image)==CGImage.typeID else{return ["invalidImageType":true]}
        return ["width":image.width,"height":image.height]
    } ?? []
    return ["name":input.name,"calls":calls,"nil":images==nil,"images":values,"typedConnectionBits":connectionBits]
}
