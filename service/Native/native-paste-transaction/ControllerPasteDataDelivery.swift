import Foundation

/// No active/stopped guard is added after restoration. A retained
/// provider may still satisfy a later request; only rearming is cleared.
struct ControllerPasteDataDelivery<Instant> {
    let now: () -> Instant
    let started: (Instant) -> Void
    let representation: (String) -> Data?
    let setData: (Data, String) -> Bool
    let markFailed: () -> Void
    let finished: (Instant, Instant, Bool) -> Void
    let yieldRead: () -> Void
    let enqueueRearm: (String) -> Void
    func provide(_ type: String) {
        let start = now()
        started(start)
        if let data = representation(type), setData(data, type) {
            finished(start, now(), true)
            yieldRead()
            enqueueRearm(type)
        } else {
            markFailed()
            finished(start, now(), false)
        }
    }
}
