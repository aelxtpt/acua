import Foundation

@MainActor extension LockScreenAutomationComponents where Backend==LockScreenNativeAXBackend{
    static func native(broker:LockScreenLoginAuthorizationBroker,isAutoUnlockEnabled:@escaping ()->Bool,
                       wallpaper:any LockScreenWallpaperProviding,nextEventNumber:@escaping ()->Int64,
                       transaction:@escaping ()->LockScreenNativeAXBackend.Transaction?={nil},
                       profileError:@escaping(Error)->Void={_ in},wallpaperError:@escaping(Error)->Void={_ in})->Self{
        let presenter=SystemLockScreenOverlayPresenter(backend:LockScreenNativeOverlayBackend(wallpaper:wallpaper,
            profileError:profileError,wallpaperError:wallpaperError))
        return .native(broker:broker,isAutoUnlockEnabled:isAutoUnlockEnabled,overlayPresenter:presenter,
            nextEventNumber:nextEventNumber,transaction:transaction)
    }
}
