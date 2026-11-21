import Foundation

enum LockScreenOverlayLayout {
    static let title="Aex Computer Use is Using Your Mac"
    static let subtitle="Press any key or click to unlock"
    static let fallbackSymbol="person.crop.circle.fill"
    static let windowCollectionBehavior:UInt=273
    static let centerOffset:CGFloat=33.5
    static let tintAlpha:CGFloat=0.28
    static let avatarSize:CGFloat=78,avatarCornerRadius:CGFloat=39
    static let avatarBorder:CGFloat=2,avatarBorderAlpha:CGFloat=0.92
    static let shadowBackgroundAlpha:CGFloat=0.001,shadowAlpha:CGFloat=0.42
    static let shadowRadius:CGFloat=18,shadowOffset=CGSize(width:0,height:-6)
    static let emblemSize:CGFloat=85,applicationIconSize:CGFloat=44
    static let titleFontSize:CGFloat=15,subtitleFontSize:CGFloat=12,textAlpha:CGFloat=0.5
    static let titleSize=CGSize(width:194,height:18),subtitleSize=CGSize(width:186,height:14)
    static let textSpacing:CGFloat=15,emblemSpacing:CGFloat=19,emblemOffset:CGFloat=4.5
}
