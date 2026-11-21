import Foundation
import CoreGraphics

enum SettingsAccessoryLayout {
    static func contentFrame(windowQuartz: CGRect,primaryScreenHeight: CGFloat,fittingSize: CGSize,audioHeading: CGRect?) -> CGRect {
        var bottom=primaryScreenHeight-windowQuartz.minY-windowQuartz.height
        if let audioHeading {
            let adjusted=primaryScreenHeight-windowQuartz.minY-audioHeading.minY-abs(fittingSize.height)
            if bottom <= adjusted { bottom=adjusted }
        }
        return CGRect(x:windowQuartz.maxX-fittingSize.width-10,y:bottom+10,width:fittingSize.width,height:fittingSize.height).integral
    }
    static func arrowFrame(accessory: CGRect) -> CGRect {
        CGRect(x:accessory.minX+31,y:accessory.minY+60,width:100,height:100)
    }
    static func acceptsDrop(_ point: CGPoint,windowQuartz: CGRect,primaryScreenHeight: CGFloat) -> Bool {
        windowQuartz.contains(CGPoint(x:point.x,y:primaryScreenHeight-point.y))
    }
}

