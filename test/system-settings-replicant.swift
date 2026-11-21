import AppKit

@main struct ReplicantChecks {
    @MainActor static func main() throws {
        var checks=[[String:Any]]()
        func check(_ label:String,_ value:Bool) {
            checks.append(["name":label,"passed":value]);precondition(value,label);print("PASS \(label)");fflush(stdout)
        }
        let artwork=NSView()
        let root=SystemSettingsTransitionReplicantView(frame:CGRect(x:0,y:0,width:1920,height:1080),artwork:artwork)
        let screen=CGRect(x:-1920,y:200,width:1920,height:1080)
        root.setReplicaFrame(CGRect(x:-1800.25,y:300.5,width:100.5,height:60.25),on:screen)
        check("fractional placement uses screen origin, 30 point padding and integral outer frame",root.replicaContainer.frame == CGRect(x:89,y:70,width:162,height:121))
        check("replica moves inside a fixed full-screen root",root.frame == CGRect(x:0,y:0,width:1920,height:1080))
        check("constraints inset artwork by thirty points",root.clippingView.frame == CGRect(x:30,y:30,width:102,height:61) && artwork.frame == CGRect(x:0,y:0,width:102,height:61))
        check("native stroke overlays the clipping view",root.strokeOverlayView.frame == root.clippingView.frame && root.stroke.frame == CGRect(x:0,y:0,width:102,height:61))
        check("stroke is a half point line inset by a quarter point",root.stroke.lineWidth == 0.5 && root.stroke.path?.boundingBoxOfPath == CGRect(x:0.25,y:0.25,width:101.5,height:60.5))
        let shadows=[root.destinationShadow,root.keyShadow,root.ambientShadow]
        check("three shadows use their radii and offsets",shadows.map(\.shadowRadius) == [2,15,3] && shadows.map(\.shadowOffset) == [CGSize(width:0,height:-3),CGSize(width:0,height:-5),.zero])
        check("shadow alpha configuration is preserved",shadows.map(\.shadowOpacity) == [0.06,0.09,0.2])
        check("shadow frames share the padded bounds",shadows.allSatisfy { $0.frame == root.replicaContainer.bounds && $0.mask?.frame == root.replicaContainer.bounds })
        check("shadow paths use the interior clipping frame",shadows.allSatisfy { $0.shadowPath?.boundingBoxOfPath == root.clippingView.frame })
        check("even odd masks remove the artwork interior",shadows.allSatisfy {
            guard let mask=$0.mask as? CAShapeLayer,let path=mask.path else { return false }
            return mask.fillRule == .evenOdd && path.contains(CGPoint(x:10,y:10),using:.evenOdd) && !path.contains(CGPoint(x:80,y:60),using:.evenOdd)
        })
        check("padded container preserves overflow after AppKit layout",root.replicaContainer.layer?.masksToBounds == false)
        let masksAfterLayout=[root.replicaContainer,root.clippingView,root.strokeOverlayView].map { $0.layer?.masksToBounds ?? false }
        root.setCornerRadius(91)
        check("raw radius is retained even above half the artwork height",root.cornerRadius == 91 && [root.replicaContainer,root.clippingView,root.strokeOverlayView].allSatisfy { $0.layer?.cornerRadius == 91 })
        root.setCornerRadius(0.1)
        check("small radius uses a zero stroke radius without losing the path",root.stroke.path != nil && root.cornerRadius == 0.1)
        root.setProgress(-1)
        check("layer progress clamps below zero",root.destinationShadow.opacity == 0 && root.stroke.opacity == 0)
        root.setProgress(0.25)
        check("destination and stroke fade independently of image availability",root.destinationShadow.opacity == 0.25 && root.stroke.opacity == Float(0.0375))
        root.setProgress(2)
        check("layer progress clamps above one",root.destinationShadow.opacity == 1 && root.stroke.opacity == Float(0.15))
        root.setProgress(.nan)
        check("layer ordered comparisons preserve NaN",root.destinationShadow.opacity.isNaN && root.stroke.opacity.isNaN)
        root.setReplicaFrame(CGRect(x:-100,y:400,width:-80,height:-40),on:screen)
        check("negative raw dimensions use CGRect width and height getters",root.replicaContainer.frame == CGRect(x:1790,y:170,width:140,height:100))
        check("size changes relayout artwork and stroke",artwork.frame.size == CGSize(width:80,height:40) && root.stroke.frame.size == CGSize(width:80,height:40))
        let lastStroke=root.stroke.path
        root.replicaContainer.frame = .zero
        root.updatePaths()
        check("empty containers clear all shadow and mask paths",shadows.allSatisfy { $0.shadowPath == nil && ($0.mask as? CAShapeLayer)?.path == nil })
        check("empty branch retains the prior stroke path",root.stroke.path == lastStroke)
        check("offscreen layer updates create no implicit animation",(shadows+[root.stroke]).allSatisfy { ($0.animationKeys() ?? []).isEmpty })
        check("no native window is created",root.window == nil && artwork.window == nil)
        let result:[String:Any]=["passed":true,"cases":checks.count,"results":checks,"nativeWindowInputCaptureExecuted":false,"ownedOffscreenViewsExecuted":true,"AppKitLayerMasksAfterLayout":masksAfterLayout]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    }
}
