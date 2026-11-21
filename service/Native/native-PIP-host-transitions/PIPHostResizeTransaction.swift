import CoreGraphics
import Foundation

enum PIPHostResizePhase: Sendable { case changed,settled
    var kind:String { self == .changed ? "resize-in-progress":"resize" }
    var failureMessage:String { self == .changed ? "Resize progress notification failed":"Source resize failed" }
}

/// Independent progress and settled fence transactions. Current publication
/// identity is deliberately not rechecked after an awaited reply.
@MainActor struct PIPHostResizeTransaction<Producer:AnyObject,Renderer,Fence> {
    struct Snapshot {
        let owner:AnyObject
        let producer:Producer
        let renderer:Renderer?
    }
    struct Environment {
        let snapshot: (PIPHostResizePhase) throws -> Snapshot
        let missingState: () -> any Error
        let missingFence: () -> any Error
        let createFence: (Producer) -> Fence?
        let operation: () -> UInt64
        let contextID: (Producer) -> UInt32
        let prepare: @MainActor (String,UInt64,UInt32,CGSize,Fence) async throws -> Void
        let setFence: (Producer,Fence) -> Void
        let nextLayoutGeneration: () -> UInt64
        let resize: @MainActor (Renderer,Producer,UInt64,CGSize) async throws -> Void
        let didResize: (CGSize) -> Void
        let complete: @MainActor (UInt64) async throws -> Void
        let releaseFence: (Fence) -> Void
        let advanceOperation: () -> Void
        let resume: (Renderer) -> Void
    }
    let environment:Environment
    func perform(_ phase:PIPHostResizePhase,size:CGSize) async throws {
        let api=environment,state=try api.snapshot(phase)
        defer { withExtendedLifetime(state) {} }
        if phase == .settled,state.renderer==nil { throw api.missingState() }
        guard let fence=api.createFence(state.producer) else {
            if phase == .settled,let renderer=state.renderer { api.resume(renderer) }
            throw api.missingFence()
        }
        let operation=api.operation(),context=api.contextID(state.producer)
        do {
            try await api.prepare(phase.kind,operation,context,size,fence)
            api.setFence(state.producer,fence)
            if phase == .settled,let renderer=state.renderer {
                let generation=api.nextLayoutGeneration()
                try await api.resize(renderer,state.producer,generation,size)
                api.didResize(size)
            }
            try await api.complete(operation)
        } catch {
            api.releaseFence(fence)
            if phase == .settled,let renderer=state.renderer { api.resume(renderer) }
            throw error
        }
        api.releaseFence(fence)
        api.advanceOperation()
        if phase == .settled,let renderer=state.renderer { api.resume(renderer) }
    }
}
