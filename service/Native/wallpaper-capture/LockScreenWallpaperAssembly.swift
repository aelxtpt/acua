import Foundation

@MainActor extension LockScreenAutomationComponents where Backend==LockScreenNativeAXBackend {
    static func nativeWithWallpaper(broker:LockScreenLoginAuthorizationBroker,isAutoUnlockEnabled:@escaping ()->Bool,
        overrideWallpaperEnabled:@escaping ()->Bool,nextEventNumber:@escaping ()->Int64,
        transaction:@escaping ()->LockScreenNativeAXBackend.Transaction?={nil},
        profileError:@escaping(Error)->Void={_ in},wallpaperDiagnostic:@escaping(WallpaperCaptureDiagnostic,UInt32,(any Error)?)->Void={_,_,_ in}) -> Self {
        let wallpaper=WallpaperNativeProviderRegistry.overlay(overrideEnabled:overrideWallpaperEnabled,diagnostic:wallpaperDiagnostic)
        return .native(broker:broker,isAutoUnlockEnabled:isAutoUnlockEnabled,wallpaper:wallpaper,nextEventNumber:nextEventNumber,
            transaction:transaction,profileError:profileError,wallpaperError:{wallpaperDiagnostic(.capture,0,$0)})
    }
}
