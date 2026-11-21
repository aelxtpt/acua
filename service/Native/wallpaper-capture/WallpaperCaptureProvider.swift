import Foundation

@MainActor final class WallpaperCaptureProvider<Backend:WallpaperCaptureBackend> {
    let backend:Backend
    let resolution:WallpaperCaptureResolution
    private var updaters=[UInt32:Task<Void,Never>]()
    private var listeners=[UInt32:Set<Int>]()
    private var imageCache=[UInt32:Backend.Image]()
    private var events=[UInt32:any WallpaperCaptureEvents]()
    private var notifications=[Int:AsyncThrowingStream<Backend.Image,Error>.Continuation]()
    private var currentID=0
    struct Snapshot:Equatable {
        let updaterDisplays:Set<UInt32>,listeners:[UInt32:Set<Int>],cachedDisplays:Set<UInt32>,eventDisplays:Set<UInt32>
        let notificationIDs:Set<Int>,nextID:Int
    }
    var snapshot:Snapshot {.init(updaterDisplays:Set(updaters.keys),listeners:listeners,cachedDisplays:Set(imageCache.keys),
        eventDisplays:Set(events.keys),notificationIDs:Set(notifications.keys),nextID:currentID)}
    init(backend:Backend,resolution:WallpaperCaptureResolution){self.backend=backend;self.resolution=resolution}
    func cachedWallpaper(for screen:Backend.Screen?)->Backend.Image? {
        guard let screen,let id=backend.displayID(for:screen) else{return nil}
        return imageCache[id]
    }
    func monitorWallpaper(for screen:Backend.Screen)throws->AsyncThrowingStream<Backend.Image,Error> {
        let pair=AsyncThrowingStream<Backend.Image,Error>.makeStream(bufferingPolicy:.bufferingNewest(1))
        if backend.overrideEnabled(),let image=backend.overrideImage(){
            pair.continuation.yield(image);pair.continuation.finish();return pair.stream
        }
        guard let display=backend.displayID(for:screen) else{throw WallpaperCaptureError.missingDisplayID}
        let listener=currentID
        pair.continuation.onTermination={ [self] _ in
            Task{@MainActor in removeListener(display:display,listener:listener)}
        }
        if let image=imageCache[display]{pair.continuation.yield(image)}
        if listeners[display]==nil {
            let source=backend.makeEvents()
            events[display]=source
            updaters[display]=Task{@MainActor [weak self,source] in
                for await _ in source.stream {
                    guard let self else{return}
                    if backend.screenLocked()==true {
                        backend.report(.waitingForUnlock,displayID:display,error:nil)
                        guard await backend.waitUntilUnlocked() else{return}
                    }
                    // Errors finish this snapshot; success broadcasts to current subscribers.
                    let recipients=(listeners[display] ?? []).compactMap{notifications[$0]}
                    let request=backend.request(for:screen,id:display,resolution:resolution)
                    do{
                        let image=try await backend.capture(request)
                        backend.report(.captureCompleted,displayID:display,error:nil)
                        receive(image,display:display)
                    }
                    catch{
                        for recipient in recipients {
                            if error is CancellationError{recipient.finish()}
                            else{backend.report(.capture,displayID:display,error:error);recipient.finish(throwing:error)}
                        }
                    }
                }
            }
        }
        listeners[display,default:[]].insert(listener)
        notifications[listener]=pair.continuation
        currentID+=1
        return pair.stream
    }
    func prepareWallpaper(for screen:Backend.Screen) {
        guard let display=backend.displayID(for:screen) else{return}
        let request=backend.request(for:screen,id:display,resolution:resolution)
        Task{
            do{
                let image=try await backend.capture(request)
                backend.report(.preparationCompleted,displayID:display,error:nil)
                Task{@MainActor in receive(image,display:display)}
            }catch{backend.report(.preparation,displayID:display,error:error)}
        }
    }
    private func receive(_ image:Backend.Image,display:UInt32) {
        imageCache[display]=image
        let recipients=(listeners[display] ?? []).compactMap{notifications[$0]}
        for recipient in recipients{recipient.yield(image)}
    }
    private func removeListener(display:UInt32,listener:Int) {
        guard listeners[display] != nil else{
            backend.report(.missingSubscription,displayID:display,error:nil);return
        }
        listeners[display]?.remove(listener);notifications[listener]=nil
        if listeners[display]?.isEmpty==true {
            updaters[display]?.cancel()
            listeners[display]=nil;updaters[display]=nil;events[display]=nil
        }
    }
    // deinit releases dictionaries; it does not cancel tasks.
}
