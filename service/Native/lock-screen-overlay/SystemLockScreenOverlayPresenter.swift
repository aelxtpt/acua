import Foundation
import Combine

@MainActor struct LockScreenOverlayScreenObservation {
    let remove: () -> Void
    // Releasing this wrapper alone does not remove it.
}
@MainActor protocol LockScreenOverlayBackend {
    associatedtype Screen
    associatedtype Window
    associatedtype WallpaperTarget: AnyObject
    associatedtype Wallpaper: Sendable
    associatedtype ProfileImage
    func screens() -> [Screen]
    func makeWindow(for screen:Screen,profile:() -> ProfileImage,
                    configureWallpaper:(WallpaperTarget) -> Void) -> Window
    func orderOut(_ window:Window)
    func orderFront(_ window:Window)
    func observeScreens(_ changed:@escaping @MainActor () -> Void) -> LockScreenOverlayScreenObservation
    func loadProfileImage() -> ProfileImage?
    func fallbackProfileImage() -> ProfileImage
    func cachedWallpaper(for screen:Screen) -> Wallpaper?
    func monitorWallpaper(for screen:Screen) throws -> AsyncThrowingStream<Wallpaper,Error>
    func setWallpaper(_ image:Wallpaper?,on target:WallpaperTarget)
    func wallpaperFailed(_ error:Error)
}

@MainActor final class SystemLockScreenOverlayPresenter<Backend:LockScreenOverlayBackend>:LockScreenOverlayPresenter {
    let backend:Backend
    private var windows=[Backend.Window]()
    private var wallpaperMonitoring=[AnyCancellable]()
    private var screenObserver:LockScreenOverlayScreenObservation?
    private var cachedProfileImage:Backend.ProfileImage?
    private var hasLoadedProfileImage=false
    struct Snapshot {
        let windows:Int,wallpaperTasks:Int
        let observesScreens:Bool,hasCachedProfileImage:Bool,hasLoadedProfileImage:Bool
    }
    var snapshot:Snapshot { .init(windows:windows.count,wallpaperTasks:wallpaperMonitoring.count,
        observesScreens:screenObserver != nil,hasCachedProfileImage:cachedProfileImage != nil,hasLoadedProfileImage:hasLoadedProfileImage) }
    init(backend:Backend){self.backend=backend}
    func present(){
        guard windows.isEmpty else{return}
        rebuild()
        screenObserver=backend.observeScreens{[weak self] in self?.rebuild()}
    }
    func dismiss(){
        screenObserver?.remove();screenObserver=nil
        wallpaperMonitoring.removeAll()
        for window in windows{backend.orderOut(window)}
        windows.removeAll();cachedProfileImage=nil;hasLoadedProfileImage=false
    }
    private func rebuild(){
        wallpaperMonitoring.removeAll()
        for window in windows{backend.orderOut(window)}
        let screens=backend.screens()
        let replacement=screens.map{screen in
            backend.makeWindow(for:screen,profile:{[self] in profileImage()},configureWallpaper:{[self] target in
                monitorWallpaper(for:screen,target:target)
            })
        }
        windows=replacement
        for window in windows{backend.orderFront(window)}
    }
    private func profileImage()->Backend.ProfileImage{
        if !hasLoadedProfileImage{
            cachedProfileImage=backend.loadProfileImage();hasLoadedProfileImage=true
        }
        if let cachedProfileImage{return cachedProfileImage}
        return backend.fallbackProfileImage()
    }
    private func monitorWallpaper(for screen:Backend.Screen,target:Backend.WallpaperTarget){
        backend.setWallpaper(backend.cachedWallpaper(for:screen),on:target)
        do{
            let stream=try backend.monitorWallpaper(for:screen),backend=backend
            let task=Task{@MainActor [weak target] in
                do{
                    for try await image in stream{
                        guard let target else{return}
                        backend.setWallpaper(image,on:target)
                    }
                }catch{if !(error is CancellationError){backend.wallpaperFailed(error)}}
            }
            wallpaperMonitoring.append(AnyCancellable{task.cancel()})
        }catch{backend.wallpaperFailed(error)}
    }
    // The destructor releases windows/tokens/observer/profile without hiding.
}
