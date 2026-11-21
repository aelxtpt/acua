import Foundation

struct WallpaperScreenUnlockEnvironment:Sendable {
    var locked:@Sendable ()->Bool?
    var nextNotification:@Sendable (String) async -> Bool
    var sleep:@Sendable (Duration) async throws -> Void
}
enum WallpaperScreenUnlockWaiter {
    static let notifications=["com.apple.screenIsUnlocked","com.apple.sessionagent.screenIsUnlocked"]
    static func wait(_ environment:WallpaperScreenUnlockEnvironment) async -> Bool {
        await withTaskGroup(of:Bool.self){group in
            for name in notifications {
                group.addTask{await environment.nextNotification(name) && !Task.isCancelled}
            }
            group.addTask{
                while !Task.isCancelled {
                    guard environment.locked()==true else{return true}
                    do{try await environment.sleep(.milliseconds(100))}catch{return false}
                }
                return false
            }
            let result=await group.next() ?? false
            group.cancelAll();return result
        }
    }
}
