import Foundation

@MainActor final class WallpaperProviderSlot<Provider> {
    private var value:Provider?
    func get(_ make:()->Provider)->Provider {
        if let value{return value}
        let value=make();self.value=value;return value
    }
}
@MainActor enum WallpaperNativeProviderRegistry {
    // The overlay slot uses a once-token separate from the shared Fog provider.
    private static let overlaySlot=WallpaperProviderSlot<LockScreenNativeWallpaperProvider>()
    private static let sharedSlot=WallpaperProviderSlot<LockScreenNativeWallpaperProvider>()
    static func overlay(overrideEnabled:@escaping ()->Bool,diagnostic:@escaping(WallpaperCaptureDiagnostic,UInt32,(any Error)?)->Void)->LockScreenNativeWallpaperProvider {
        overlaySlot.get{.init(resolution:.nativeScale,overrideEnabled:overrideEnabled,diagnostic:diagnostic)}
    }
    static func shared(overrideEnabled:@escaping ()->Bool,diagnostic:@escaping(WallpaperCaptureDiagnostic,UInt32,(any Error)?)->Void)->LockScreenNativeWallpaperProvider {
        sharedSlot.get{.init(resolution:.scaled(0.125),overrideEnabled:overrideEnabled,diagnostic:diagnostic)}
    }
}
