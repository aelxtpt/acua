import CoreGraphics

/// Keep the Bezier control construction/order, including
/// the quarter-endpoint correction and the fused size interpolation.
enum SystemSettingsTransitionGeometry {
    static func frame(from source: CGRect,to target: CGRect,progress p: CGFloat,lift: CGFloat = 50) -> CGRect {
        let sx=source.midX,sy=source.midY,tx=target.midX,ty=target.midY
        var cx=(sx+tx)*0.5-sx*0.25-tx*0.25
        let higher=sy <= ty ? ty:sy
        var cy=higher+lift-sy*0.25-ty*0.25
        cx=cx+cx;cy=cy+cy
        let remaining=1-p,p2=p*p,q2=remaining*remaining,middle=(remaining+remaining)*p
        let centerX=p2*tx+(q2*sx+middle*cx)
        let centerY=p2*ty+(q2*sy+middle*cy)
        let width=source.width.addingProduct(p,target.width-source.width)
        let height=source.height.addingProduct(p,target.height-source.height)
        return CGRect(x:centerX-width*0.5,y:centerY-height*0.5,width:width,height:height)
    }
}
