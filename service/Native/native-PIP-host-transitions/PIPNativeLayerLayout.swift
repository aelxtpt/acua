import AppKit
import AVFoundation

/// A shared native layout for prepare and subsequent hosted resizes.
@MainActor enum PIPNativeLayerLayout {
    static func apply(size:CGSize,root:CALayer,video:AVSampleBufferDisplayLayer,cursor:AVSampleBufferDisplayLayer,
                      hasCursorGeometry:Bool,layoutCursor:() -> Void) {
        CATransaction.begin();CATransaction.setDisableActions(true)
        root.frame=CGRect(origin:.zero,size:size)
        root.backgroundColor=NSColor.clear.cgColor
        root.masksToBounds=true
        video.frame=root.bounds
        video.videoGravity = .resizeAspect
        cursor.videoGravity = .resize
        cursor.backgroundColor=NSColor.clear.cgColor
        if video.superlayer !== root || cursor.superlayer !== root { root.sublayers=[video,cursor] }
        if hasCursorGeometry { layoutCursor() } else { cursor.isHidden=true }
        CATransaction.commit();CATransaction.flush()
    }
}
