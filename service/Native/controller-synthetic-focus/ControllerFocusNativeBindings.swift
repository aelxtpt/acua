import AppKit
import ApplicationServices
import Foundation
import os

/// Required PID-keyed global dependency. The UUID/process-key based legacy
/// FocusStealPreventer is deliberately not advertised as an equivalent binding.
struct ControllerFocusPreventionBindings: Sendable {
    let register: @Sendable (Int32, @escaping @Sendable () -> Void, @escaping @Sendable () -> Void) -> Void
    let unregisterIfPresent: @Sendable (Int32) -> Void
    let currentlyFocused: @Sendable (Int32) -> Bool
    let startMenuIfPresent: @Sendable (Int32, Int32?) -> Void
    let stopMenuIfPresent: @Sendable (Int32) -> Void
}
struct ControllerFocusWindowServerBindings: Sendable {
    // Connection values occupy a full pointer-sized register.
    let mainConnection: @Sendable () -> UInt
    let disableUpdates: @Sendable (UInt) -> Void
    let reenableUpdates: @Sendable (UInt) -> Void
    let setWindowLocation: @Sendable (ControllerFocusNativeEvent, CGPoint) -> Void
}
final class ControllerFocusSynthesizedActionState: @unchecked Sendable {
    static let shared = ControllerFocusSynthesizedActionState()
    private let lock = NSLock()
    // The final byte is the optional tuple's nil flag; the static
    // initializer has byte 1. synthesizedActionWasPerformed stores byte 0.
    private var stored: (Double, Int32, Bool) = (0,0,true)
    func record(_ uptime: Double, _ pid: Int32, _ flag: Bool) { lock.withLock { stored = (uptime,pid,flag) } }
    var value: (Double, Int32, Bool) { lock.withLock { stored } }
}

enum ControllerFocusNativeBindings {
    typealias Focus = ControllerSyntheticFocus<ControllerAXEnablementApplication, ControllerNativeElementContext.Node, ControllerFocusNativeEvent>
    typealias Node = ControllerNativeElementContext.Node

    /// The caller supplies the shared transaction-aware geometry/action
    /// providers and the PID-keyed prevention resource. No raw AX
    /// geometry fallback silently bypasses a cached or hosted node.
    static func environment(context: ControllerNativeElementContext,
        prevention: ControllerFocusPreventionBindings, windowServer: ControllerFocusWindowServerBindings,
        activationPoint: @escaping @Sendable (Node) -> CGPoint??,
        frame: @escaping @Sendable (Node) -> CGRect?, raise: @escaping @Sendable (Node) throws -> Void,
        synthesizedActions: ControllerFocusSynthesizedActionState = .shared) -> Focus.Environment {
        let packets = ControllerFocusNativeEvents(setWindowLocation: windowServer.setWindowLocation)
        return .init(makeTracker: { ControllerFocusNativeTracking() }, makeTap: { ControllerFocusNativeTap($0) },
            registerPrevention: prevention.register, unregisterPreventionIfPresent: prevention.unregisterIfPresent,
            currentlyFocused: prevention.currentlyFocused, isActive: { NSRunningApplication(processIdentifier:$0)?.isActive ?? false },
            integer: { $0.event.getIntegerValueField(CGEventField(rawValue:$1)!) }, subtypeField:83, windowUnderPointerField:51,
            resignedKeySubtype:22, resignedMainSubtype:23, processIdentifier:{ getpid() },
            windowOwner:{ ControllerWindowDescription.lookup($0)?.ownerPID },
            activatePID:{ pid in
                guard let app=NSRunningApplication(processIdentifier:pid) else {
                    Logger(subsystem:"local.cua",category:"SyntheticFocus").error("Unable to resolve click target PID \(pid)"); return
                }
                _=app.activate(options:[])
            }, post:{ $0.event.postToPid($1) }, activationPoint:activationPoint,
            windowID:{ try context.identity.windowID($0.element) }, frame:frame,
            send:{ try packets.send($0,to:$1) }, startMenuSuppressionIfPresent:prevention.startMenuIfPresent,
            stopMenuSuppressionIfPresent:prevention.stopMenuIfPresent,
            recordSynthesizedAction:{ synthesizedActions.record($0,$1,$2) }, uptime:{ ProcessInfo.processInfo.systemUptime },
            frontmost:{ NSWorkspace.shared.frontmostApplication.map { .init(application:$0) } },
            pid:{ $0.application.processIdentifier },
            focusedWindow:{ context.context.focusedWindow(context.application(RunningApplicationPID.resolve($0.application))) },
            activate:{ $0.application.activate(options:[]) },
            targetBelievesFrontmost:{ ControllerAXEnablementNative.boolean(context.application($0),attribute:"AXFrontmost",context:context) },
            waitUntilTargetBelievesFrontmost:{ pid,timeout in
                // Snapshot once; the wall-clock timeout uses strict >,
                // 100ms continuous-clock sleeps; cancellation is swallowed.
                let application=context.application(pid)
                await waitUntilFrontmost(timeout:timeout, boolean:{
                    ControllerAXEnablementNative.boolean(application,attribute:"AXFrontmost",context:context)
                })
            }, windows:{
                let rows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],0) as? [[AnyHashable:Any]] ?? []
                return rows.map { row in
                    let value=ControllerWindowDescription(info:row)
                    return .init(id:value.id,pid:value.ownerPID,layer:Int(value.level))
                }
            }, raise:raise, mainConnection:windowServer.mainConnection,
            disableUpdates:windowServer.disableUpdates, reenableUpdates:windowServer.reenableUpdates,
            checkCancellation:{ try Task.checkCancellation() }, sleep:{ try await ContinuousClock().sleep(for:$0) })
    }

    static func waitUntilFrontmost(timeout:Double, boolean:@Sendable () -> Bool?,
        now:@Sendable () -> Date = { Date() }, sleep:@Sendable (Duration) async throws -> Void = { try await ContinuousClock().sleep(for:$0) }) async {
        let start=now()
        while true {
            if now().timeIntervalSince(start) > timeout { return }
            if boolean() == true { return }
            do { try await sleep(.milliseconds(100)) } catch { return }
        }
    }
}
