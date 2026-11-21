import AppKit
import SwiftUI

@MainActor enum WallpaperNativeImageBridge {
    static func appKit(_ image:CGImage)->NSImage {
        NSImage(cgImage:image,size:CGSize(width:image.width,height:image.height))
    }
    static func swiftUI(_ image:CGImage)->SwiftUI.Image {SwiftUI.Image(nsImage:appKit(image))}
}
