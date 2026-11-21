import Foundation

/// This owns cursor state while sharing the
///renderer's generation counter with source-loss and full stop.
@MainActor final class PIPCursorCaptureController<Payload,Capture:AnyObject> {
    struct Plan {
        let payload: Payload
        let key: PIPCursorCaptureKey
        let geometry: PIPCursorLayerGeometry
    }
    struct Environment {
        let sourceUnavailable: () -> Bool
        let advanceGeneration: () -> Int
        let layout: (PIPCursorLayerGeometry) -> Void
        let hideAndFlush: () -> Void
        let makeCapture: (Payload,Int) -> Capture
        let start: @MainActor (Capture) async throws -> Void
        let stop: @MainActor (Capture) async throws -> Void
    }
    private(set) var capture: Capture?
    private(set) var key: PIPCursorCaptureKey?
    private(set) var geometry: PIPCursorLayerGeometry?
    private let environment: Environment
    init(environment:Environment) { self.environment=environment }

    func refresh(plan: () async throws -> Plan?) async {
        guard !environment.sourceUnavailable() else { return }
        do {
            guard let next=try await plan() else { await clear();return }
            geometry=next.geometry
            environment.layout(next.geometry)
            if key==next.key,capture != nil { return }
            try await replace(next)
        } catch { await clear() }
    }
    private func replace(_ plan:Plan) async throws {
        let generation=environment.advanceGeneration()
        let previous=capture
        capture=nil;key=nil
        if let previous { try? await environment.stop(previous) }
        let next=environment.makeCapture(plan.payload,generation)
        capture=next;key=plan.key
        do { try await environment.start(next) }
        catch {
            if capture===next { capture=nil;key=nil }
            throw error
        }
    }
    func clear() async {
        _=environment.advanceGeneration()
        key=nil;geometry=nil
        environment.hideAndFlush()
        let previous=capture;capture=nil
        if let previous { try? await environment.stop(previous) }
    }
    ///Source loss/full stop already advanced the generation and hid the layer.
    func detach() -> Capture? {
        let previous=capture;capture=nil;key=nil;geometry=nil
        return previous
    }
}
