import Foundation

struct LockScreenProfileImageLoader<Record,Image> {
    static var jpegAttribute:String{"dsAttrTypeStandard:JPEGPhoto"}
    static var pictureAttribute:String{"dsAttrTypeStandard:Picture"}
    var userName:()->String
    var record:(UInt32,String,[String]) throws -> Record
    var values:(Record,String) throws -> [Any]
    var decodeData:(Data)->Image?
    var decodePath:(String)->Image?
    func load() throws -> Image?{
        let name=userName(),attributes=[Self.jpegAttribute,Self.pictureAttribute]
        let record:Record
        do{record=try self.record(8705,name,attributes)}
        catch{record=try self.record(8704,name,attributes)}
        if let values=try? values(record,Self.jpegAttribute){
            for value in values{
                if let data=value as? Data,let image=decodeData(data){return image}
                // Try NSData separately after a failed Data decode.
                if let bytes=value as? NSData,let image=decodeData(bytes as Data){return image}
            }
        }
        if let values=try? values(record,Self.pictureAttribute){
            for value in values{if let path=value as? String,let image=decodePath(path){return image}}
        }
        return nil
    }
}
