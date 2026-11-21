import AppKit
import CoreServices

struct WallpaperEventEnvironment:Sendable {
    let sleep:@Sendable (Duration,Duration) async throws -> Void
    let filesystem:@Sendable (AsyncStream<Void>.Continuation) async throws -> Void
    let space:@MainActor @Sendable (AsyncStream<Void>.Continuation) async -> Void
    let filesystemFailure:@MainActor @Sendable (any Error) -> Void
}
final class WallpaperNativeEvents:WallpaperCaptureEvents {
    let stream:AsyncStream<Void>
    private let continuation:AsyncStream<Void>.Continuation
    private let timer:Task<Void,Never>
    private let filesystem:Task<Void,Error>
    private let space:Task<Void,Never>
    init(environment:WallpaperEventEnvironment) {
        let (stream,continuation)=AsyncStream<Void>.makeStream(bufferingPolicy:.unbounded)
        self.stream=stream;self.continuation=continuation
        timer=Task{
            while true {
                continuation.yield()
                do{try await environment.sleep(.seconds(600),.seconds(60))}catch{return}
            }
        }
        filesystem=Task{
            do{
                try await environment.filesystem(continuation)
            }catch{await environment.filesystemFailure(error);throw error}
        }
        space=Task{@MainActor in
            await environment.space(continuation)
        }
    }
    @MainActor convenience init(diagnostic:@escaping @MainActor @Sendable(WallpaperCaptureDiagnostic,UInt32,(any Error)?)->Void) {
        self.init(environment:.init(sleep:{try await ContinuousClock().sleep(for:$0,tolerance:$1)},filesystem:{continuation in
            let directory=URL.applicationSupportDirectory.appendingPathComponent("com.apple.wallpaper").appendingPathComponent("Store")
            let updates=try WallpaperFileEvents.monitor(directory)
            for await _ in updates{continuation.yield()}
        },space:{continuation in
            for await _ in NSWorkspace.shared.notificationCenter.notifications(named:NSWorkspace.activeSpaceDidChangeNotification){continuation.yield()}
        },filesystemFailure:{diagnostic(.filesystem,0,$0)}))
    }
    deinit{
        timer.cancel();filesystem.cancel();continuation.finish()
        // deinit releases the space Task handle without cancelling it.
    }
}

private final class WallpaperFileEventContext:Sendable {
    let continuation:AsyncStream<Void>.Continuation
    init(_ continuation:AsyncStream<Void>.Continuation){self.continuation=continuation}
}
private final class WallpaperFileEventOwner:@unchecked Sendable {
    private let lock=NSLock()
    private var source:FSEventStreamRef?
    init(_ source:FSEventStreamRef){self.source=source}
    func stop(){
        lock.lock();let source=self.source;self.source=nil;lock.unlock()
        if let source{FSEventStreamStop(source);FSEventStreamInvalidate(source);FSEventStreamRelease(source)}
    }
    deinit{stop()}
}
enum WallpaperFileEvents {
    enum Failure:Error {case create,start}
    static func monitor(_ directory:URL)throws->AsyncStream<Void> {
        let (stream,continuation)=AsyncStream<Void>.makeStream(bufferingPolicy:.unbounded)
        let box=WallpaperFileEventContext(continuation)
        var context=FSEventStreamContext(version:0,info:Unmanaged.passUnretained(box).toOpaque(),retain:{pointer in
            guard let pointer else{return nil};_ = Unmanaged<WallpaperFileEventContext>.fromOpaque(pointer).retain();return pointer
        },release:{pointer in
            if let pointer{Unmanaged<WallpaperFileEventContext>.fromOpaque(pointer).release()}
        },copyDescription:nil)
        guard let source=FSEventStreamCreate(nil,{_,info,_,_,_,_ in
            if let info{Unmanaged<WallpaperFileEventContext>.fromOpaque(info).takeUnretainedValue().continuation.yield()}
        },&context,[directory.path] as CFArray,FSEventStreamEventId(kFSEventStreamEventIdSinceNow),1.0,0) else{throw Failure.create}
        let owner=WallpaperFileEventOwner(source)
        FSEventStreamSetDispatchQueue(source,DispatchQueue.global())
        guard FSEventStreamStart(source) else{owner.stop();throw Failure.start}
        continuation.onTermination={_ in owner.stop()}
        return stream
    }
}
