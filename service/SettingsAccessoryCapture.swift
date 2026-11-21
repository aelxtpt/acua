import Foundation
import CoreGraphics

struct SettingsAccessoryCapture<Artwork: Sendable>: Sendable {
    var frameOnScreen: CGRect
    var artwork: Artwork?
    var cornerRadius: CGFloat
}
