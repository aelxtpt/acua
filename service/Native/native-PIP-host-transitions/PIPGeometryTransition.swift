import CoreGraphics
import Foundation

/// Configuration and aspect waiting run independently of the publisher
/// queue. Changed/settled callbacks enqueue their own host operations.
@MainActor struct PIPGeometryTransition<Payload> {
    struct Plan { let key:PIPCaptureKey;let bounds:CGRect;let payload:Payload }
    struct Environment {
        let isCurrent: (Int) -> Bool
        let isCancelled: () -> Bool
        let bounds: () -> CGRect?
        let setBounds: (CGRect) -> Void
        let key: () -> PIPCaptureKey?
        let setKey: (Plan) -> Void
        let suspended: () -> Bool
        let suspend: () -> Void
        let resume: () -> Void
        let currentSize: () -> CGSize?
        let maximum: () -> CGFloat
        let configure: @MainActor () async throws -> Plan
        let replace: @MainActor (Payload) async throws -> Void
        let wait: @MainActor (PIPPresentationAspect) async -> PIPPresentationAspect
        let changed: (CGSize) -> Void
        let settled: (CGSize) -> Void
        let refreshCursor: @MainActor () async -> Void
        let unavailable: (String) -> Void
        let recordError: (any Error) -> Void
    }
    let environment:Environment
    func update(generation:Int) async {
        let api=environment
        do {
            guard !api.isCancelled(),api.isCurrent(generation) else { return }
            let next=try await api.configure()
            guard !api.isCancelled(),api.isCurrent(generation) else { return }
            let sameBounds=api.bounds().map { CGRectEqualToRect($0,next.bounds) } ?? false
            api.setBounds(next.bounds)
            let sameCapture=api.key()==next.key
            let suspended=api.suspended()
            if sameCapture,!suspended {
                if !sameBounds { await api.refreshCursor() }
                return
            }
            let fallback=PIPPresentationAspect(size:PIPPresentationAspectParser.fit(next.bounds.size,maximum:api.maximum()),
                reason:"geometry-fallback",sourceSize:next.bounds.size)
            if !suspended {
                api.setKey(next)
                api.suspend()
                api.changed(api.currentSize() ?? fallback.size)
                try await api.replace(next.payload)
            }
            let aspect=await api.wait(fallback)
            guard !api.isCancelled(),api.isCurrent(generation) else { return }
            api.settled(aspect.size)
            await api.refreshCursor()
        } catch is PIPCaptureFactoryError {
            if !api.isCancelled() { api.unavailable("stream-configuration-source-unavailable") }
        } catch {
            if !api.isCancelled() { api.resume();api.recordError(error) }
        }
    }
}
