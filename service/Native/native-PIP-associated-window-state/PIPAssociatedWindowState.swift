import CoreGraphics
import Foundation

/// Commit the ordered array before looking up the live recipient.
///Closures avoid holding a mutating access while notification reenters the owner.
@MainActor enum PIPAssociatedWindowState {
    static func update(_ ids:[UInt32],current:()->[UInt32],store:([UInt32])->Void,forward:([UInt32])->Void) {
        guard current() != ids else{return}
        store(ids)
        forward(ids)
    }
    /// The controller sorts, without collapsing repeated IDs.
    static func controllerIDs(_ ids:[UInt32])->[UInt32] {ids.sorted()}
    /// Fetch SC content before reading current associations.
    static func configure<Content,Plan>(fetch:@MainActor () async throws->Content,
        ids:()->[UInt32],make:(Content,[UInt32]) throws->Plan) async throws->Plan {
        let content=try await fetch()
        return try make(content,ids())
    }
}

enum PIPDisplaySizePolicy {
    static func normalizedMaximum(_ value:CGFloat)->CGFloat {
        value.isFinite ? min(400,max(100,value.rounded(.toNearestOrAwayFromZero))) : 200
    }
    /// Resize on a change of at least 0.5 in either dimension; NaN never resizes.
    static func requiresResize(current:CGSize,next:CGSize)->Bool {
        abs(current.width-next.width)>=0.5 || abs(current.height-next.height)>=0.5
    }
}
