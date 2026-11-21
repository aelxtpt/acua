import Foundation
import os

@MainActor private final class ControllerNativeCaptureObservation {
    var value: (ControllerNativeAppController,ControllerNativeAppController.AppSnapshot)?
}

///One transport-independent canonical manager. Assembly resolution is deferred
///until launch/controller creation, preserving missing-target/no-instance errors.
final class ControllerNativeUsageRuntime: Sendable {
    typealias Facade=ControllerNativeServiceFacade
    typealias Assembly=ControllerNativeAppSnapshotBackend.Assembly
    let bindings: ControllerNativeInstanceBindings
    private let makeResolver: @MainActor @Sendable () -> ControllerApplicationTargetResolver
    private let makeAssembly: @MainActor @Sendable () throws -> Assembly
    private let makeFixture: (@MainActor @Sendable () throws -> Facade)?
    private let observe: @MainActor @Sendable (ControllerNativeAppController,ControllerNativeAppController.AppSnapshot) -> Void
    @MainActor private var cachedAssembly: Assembly?
    @MainActor private var cachedFacade: Facade?
    init(bindings:ControllerNativeInstanceBindings = .init(),
         resolver:@escaping @MainActor @Sendable () -> ControllerApplicationTargetResolver = {.init(environment:.native())},
         assembly:@escaping @MainActor @Sendable () throws -> Assembly = {
            let log=Logger(subsystem:"local.cua",category:"NativeUsage")
            var assembly=try Assembly.approvedCursorNative(analytics:{log.info("Controller lifecycle: \(String(describing:$0),privacy:.public)")},
                orderingLog:{log.debug("Window ordering: \(String(describing:$0),privacy:.public)")},
                log:{log.error("\($0,privacy:.public): \(String(describing:$1),privacy:.public)")})
            return assembly
         }, fixture:(@MainActor @Sendable () throws -> Facade)? = nil,
         observe:@escaping @MainActor @Sendable (ControllerNativeAppController,ControllerNativeAppController.AppSnapshot)->Void) {
        self.bindings=bindings;makeResolver=resolver;makeAssembly=assembly;makeFixture=fixture;self.observe=observe
    }
    @MainActor private func assembly() throws -> Assembly {
        if let cachedAssembly{return cachedAssembly}
        let made=try makeAssembly();cachedAssembly=made;return made
    }
    @MainActor private func facade() throws -> Facade {
        if let cachedFacade{return cachedFacade}
        let value: Facade
        if let makeFixture{value=try makeFixture()}
        else {
            let env=ControllerNativeApplicationLifecycle.Environment(prepareLaunch:{target in
                let resources=try self.assembly().resources
                try await ControllerLaunchPreparation(backend:ControllerNativeLaunchBackend(resources:resources,environment:.native(resources:resources))).prepare(target)
            },makeController:{target,config in
                try .init(target:target,chatID:nil,mcpRuntime:config.mcpRuntime,isAXTreeDiffingEnabled:config.isAXTreeDiffingEnabled,assembly:self.assembly())
            },interventionClock:.native)
            value = .init(lifecycle:.init(bindings:bindings,environment:env),resolver:makeResolver())
        }
        precondition(value.lifecycle.bindings === bindings,"A transport runtime must use exactly its canonical manager")
        cachedFacade=value;return value
    }
    @MainActor func handle(type:String,body:Data,sender:SenderRequestContext?) async throws -> Data {
        do {
            var facade=try facade()
            let observation=ControllerNativeCaptureObservation()
            let state=facade.appSnapshotEnvironment ?? .native,action=facade.actionEnvironment ?? .native
            facade.appSnapshotEnvironment = .init(capture:{controller,diff in
                let capture=try await state.capture(controller,diff);observation.value=(controller,capture);return capture
            },blockedURL:state.blockedURL,scheduleFinished:state.scheduleFinished,instructions:state.instructions)
            facade.actionEnvironment = .init(focus:action.focus,activity:action.activity,dispatch:{controller,value,capture in
                let result=try await action.dispatch(controller,value,capture)
                if let result{observation.value=(controller,result)}
                return result
            },blockedURL:action.blockedURL)
            let data=try await facade.handle(type:type,body:body,sender:sender)
            if let (controller,capture)=observation.value{observe(controller,capture)}
            return data
        }catch let failure as ServiceError{throw failure}
        catch {throw ControllerNativeMappedError.classify(error)}
    }
    func request(type:String,body:Any,sender:SenderRequestContext?) throws -> Any {
        let bytes=try NativeResponseEncoding.encode(body)
        let data=try ControllerNativeRequestBridge.wait {try await self.handle(type:type,body:bytes,sender:sender)}
        return try JSONSerialization.jsonObject(with:data,options:[.fragmentsAllowed])
    }
    func resolveIdentifier(_ query:String) throws -> String {
        if Thread.isMainThread {
            return try MainActor.assumeIsolated {
                do{return try self.makeResolver().resolve(query).identifier}
                catch{throw ControllerNativeMappedError.classify(error)}
            }
        }
        return try ControllerNativeRequestBridge.wait {
            do{return try self.makeResolver().resolve(query).identifier}
            catch{throw ControllerNativeMappedError.classify(error)}
        }
    }
    func clearStoppedByUser(_ identifier:String){bindings.manager.clearStoppedByUser(for:identifier)}
}
