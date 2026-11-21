import Foundation
import ApplicationServices

enum EventStreamTimestampUUID {
    // Logging.UUID.init(timestamp:),0x10062F2A4. Random bytes first, timestamp
    // milliseconds truncated to UInt64, low48 bits big-endian, version7/variant.
    static func make(timestamp:Date,randomBytes:()->[UInt8]=random)->UUID {
        var bytes=randomBytes()
        precondition(bytes.count==16)
        let millis=UInt64(timestamp.timeIntervalSince1970*1000)
        for i in 0..<6 {bytes[i]=UInt8(truncatingIfNeeded:millis >> ((5-i)*8))}
        bytes[6]=(bytes[6]&0x0f)|0x70;bytes[8]=(bytes[8]&0x3f)|0x80
        return UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                          bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func random()->[UInt8] {
        var bytes=Array(repeating:UInt8(0),count:16)
        bytes.withUnsafeMutableBytes {arc4random_buf($0.baseAddress!,16)}
        return bytes
    }
}

@MainActor enum EventStreamNativeTreeRevision {
    typealias Revision=EventStreamTreeRevision<EventStreamAXNode,EventStreamSnapshotAXIdentity>
    typealias Source=EventStreamCollectedTree<EventStreamAXNode>
    //0x1007763A4/0x1007765C0: choose lineage before rendering, lowercase the
    // timestamp UUID. Omitted focus means nil; this wrapper does not derive it.
    static func root(_ tree:Source,focusTree:Source?=nil,context:inout EventStreamMacTransformationContext,
                     now:()->Date={Date()},randomBytes:(()->[UInt8])?=nil) throws->Revision {
        let date=now()
        let uuid=randomBytes.map {EventStreamTimestampUUID.make(timestamp:date,randomBytes:$0)}
            ?? EventStreamTimestampUUID.make(timestamp:date)
        return try Revision.root(tree,focusTree:focusTree,lineageID:uuid.uuidString.lowercased(),
            identity:{EventStreamSnapshotAXIdentity(element:$0.element)},
            render:{EventStreamNativeRenderForest.build($0,context:&context)})
    }
    //0x100776260/0x100776298: same current transformation context for main and
    // optional focus render. URL compaction/recapture belong to the caller.
    static func appending(_ previous:Revision,tree:Source,focusTree:Source?=nil,
                          context:inout EventStreamMacTransformationContext) throws->Revision {
        try previous.appending(tree:tree,focusTree:focusTree,
            render:{EventStreamNativeRenderForest.build($0,context:&context)})
    }
}
