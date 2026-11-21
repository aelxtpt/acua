import Foundation
import CoreGraphics

private struct Input:Decodable{let cases:[SPIInput]}
@main enum Local {
    static func main() throws {
        let arguments=CommandLine.arguments
        let input=try JSONDecoder().decode(Input.self,from:Data(contentsOf:URL(fileURLWithPath:arguments[1])))
        let connection=unsafeBitCast(unsafeBitCast(ownedConnection,to:UnsafeRawPointer.self),to:MainConnection.self)
        let capture=unsafeBitCast(unsafeBitCast(ownedImages,to:UnsafeRawPointer.self),to:WindowImages.self)
        var rows=[[String:Any]]()
        for item in input.cases {
            fputs("LOCAL_SPI_CASE \(item.name)\n",stderr)
            prepare(item)
            let value=connection()
            let images:[CGImage]?=item.ids.withUnsafeBufferPointer{buffer in
                guard let pointer=buffer.baseAddress,!item.ids.isEmpty else{return nil}
                return capture(value,pointer,Int32(item.ids.count),item.options,rectangle(item))?.takeUnretainedValue() as? [CGImage]
            }
            rows.append(summary(item,images,connectionBits:connectionBits(value)))
        }
        try JSONSerialization.data(withJSONObject:["cases":rows],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:arguments[2]))
    }
}
