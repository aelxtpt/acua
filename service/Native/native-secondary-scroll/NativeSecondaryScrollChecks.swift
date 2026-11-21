import AppKit
import ApplicationServices
import Foundation

@MainActor enum NativeSecondaryScrollChecks {
    static func run(output: URL) async throws -> Int32 {
        var checks: [[String: Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name":name,"passed":passed]); if !passed { print("FAIL: "+name) } }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let f = SecondaryScrollDataNativeFixture(), owner = try NativeSecondaryScrollDataAppSnapshotBindingChecks.owner(f)
        let appSnapshot = try NativeSecondaryScrollDataAppSnapshotBindingChecks.result(f)
        let controller = ControllerNativeAppController(owner: owner, resources: f.resources)
        let backend = ControllerNativeSecondaryBackend(controller: controller, runtime: .native(resources: f.resources))
        let tree = appSnapshot.axTree
        let node = tree.selection.value.windowRevision.tree.preorder[0].node
        var refreshed = false
        let handle = ControllerNativeResolvedElement(node: node, tree: tree, resources: f.resources,
            io: .init(roleStatus: { _ in 0 }, fresh: { value in refreshed = true; return value }, capture: { _, _ in preconditionFailure("No capture") }))
        check("native secondary actions reread hosted names instead of stale published snapshot", backend.descriptions(handle) == [.init(name:"AXPress",description:"Press"),.init(name:"AXFixtureCustomAction",description:"Hosted action")])
        f.rows.setNames(["AXCancel"])
        check("native secondary action list refreshes between reads", backend.descriptions(handle) == [.init(name:"AXCancel",description:"Cancel")])
        try backend.perform("AXFixtureAction", on: handle)
        check("native secondary action uses hosted protocol executor without post-write refetch", f.rows.actions == ["AXFixtureAction"] && !refreshed)
        let menu = f.resources.context.context.node(f.window)
        owner.currentlyOpenedMenu = menu; owner.currentlyFocusedMenuBarItem = menu
        check("cancel on non-menu-bar node preserves tracked menu", await backend.cancelMenu(handle) == false && owner.currentlyOpenedMenu != nil && owner.currentlyFocusedMenuBarItem != nil)
        f.rows.set(f.window, name:"AXRole", value:.init(raw:"AXMenuBarItem" as NSString))
        let bar = f.resources.context.context.node(f.window)
        owner.currentlyOpenedMenu = bar; owner.currentlyFocusedMenuBarItem = bar
        await backend.clearMenu(bar)
        check("native menu-bar cleanup clears both owner properties", owner.currentlyOpenedMenu == nil && owner.currentlyFocusedMenuBarItem == nil)
        f.rows.set(f.window, name:"AXRole", value:.init(raw:"AXWindow" as NSString))
        f.rows.set(f.app, name:"AXFixtureHit", value:.init(raw:f.child.element))
        let application = f.resources.context.context.node(f.app), window = f.resources.context.context.node(f.window)
        let targeting = ControllerNativeCoordinateTarget(resources: f.resources)
        let point = CGPoint(x:20,y:30)
        let target = try ControllerCoordinateTargeting(backend: targeting).target(at:point,application:application,windows:[window])
        check("native coordinate path composes hosted app hit with native mouse targeting", target.pid == 74001 && target.windowID == 51 && target.element?.element == f.child && target.accessibilityWindow.element == f.window)
        f.rows.set(f.app,name:"AXFixtureHitError",value:.init(raw:NSNumber(value:AXError.illegalArgument.rawValue)))
        check("native app-local hit masks only illegalArgument as absent", try targeting.element(at:point,application:application) == nil)
        f.rows.set(f.app,name:"AXFixtureHitError",value:.init(raw:NSNumber(value:AXError.cannotComplete.rawValue)))
        var hitFailure = false
        do { _ = try targeting.element(at:point,application:application) }
        catch ControllerNativeElementDecoding.Failure.accessibility(let status) { hitFailure = status == AXError.cannotComplete.rawValue }
        check("native app-local hit propagates cannotComplete", hitFailure)
        backend.needsUISettleBeforeAppSnapshot = true
        check("secondary deferred-settle property uses the existing owner", owner.needsUISettleBeforeAppSnapshot)
        let runtime = ControllerNativeScrollRuntime.native(resources: f.resources)
        _ = runtime // Construction must not send or create an event.
        let scroll = ControllerNativeScrollBackend(controller:controller,runtime:runtime)
        owner.cursorPositionInScaledCoordinates = .init(x:7,y:11)
        owner.scalingFactor = 2
        owner.visibleRect = .init(x:-30,y:40,width:100,height:200)
        check("native scroll point scales cursor then translates visible origin", scroll.point() == .init(x:-16,y:62))
        let ordered = ControllerNativeCoordinateTarget.orderedWindowIDs()
        check("native CGWindowListCreate pointer array decoded without object bridging", ordered.allSatisfy { $0 != 0 })
        guard let ws = ControllerNativeWindowServer.resolve() else { throw ControllerNativeMouseHitTestFailure.unsupportedHostedHitTest }
        let nativeFactory = ControllerNativeScrollEvents.factory(windowServer:ws)
        var writes: [(UInt32,Int64)] = []
        let observingFactory = ControllerScrollEventFactory(source:nativeFactory.source,create:nativeFactory.create,
            setLocation:nativeFactory.setLocation,location:nativeFactory.location,setInteger:{ event,field,value in
                writes.append((field,value)); nativeFactory.setInteger(event,field,value)
            },optionalWindowField:nativeFactory.optionalWindowField,setWindowLocation:nativeFactory.setWindowLocation)
        let events = try observingFactory.make(at:.init(x:30,y:50),deltaX:-7,deltaY:13,
            windowID:51,bounds:.init(x:10,y:20,width:100,height:200),flipped:false)
        let event = events[0].event
        check("native scroll creates one scroll-wheel event with pixel units", events.count == 1 && event.type == .scrollWheel && event.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
        // This OS ignores 91/92 writes on scroll events. Verify the exact
        // native calls without claiming unsupported fields persist in memory.
        check("native scroll preserves global point and writes all three window fields", event.location == .init(x:30,y:50) && writes.map(\.0) == [51,91,92] && writes.map(\.1) == [51,51,51] && event.getIntegerValueField(CGEventField(rawValue:51)!) == 51)
        check("native pixel-unit scroll has exact point delta from constructor", event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == 13)
        let bare = try ControllerNativeScrollEvents.factory(windowServer:ws).make(at:.init(x:-10,y:9),deltaX:0,deltaY:0,windowID:nil,bounds:nil,flipped:true)
        check("native zero-delta scroll still constructs its event", bare.count == 1 && bare[0].event.location == .init(x:-10,y:9))
        check("native checks preserve foreground application", NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        let result: [String:Any] = ["passed":passed,"cases":checks,"actual_CGEvent_construction":true,
            "actual_CGWindowListCreate_read":true,"hosted_native_secondary_and_coordinate_adapters_executed":true,
            "whole_native_controller_operations_executed":false,"actual_input_focus_capture_or_AX_write":false,
            "normal_native_request_routing_accepted":false,"foreground_unchanged":NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground,
            "scroll_91_92_readback":[91,92].map { event.getIntegerValueField(CGEventField(rawValue:UInt32($0))!) },
            "scroll_point_delta_axis1":event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1),
            "scroll_line_delta_axis1":event.getIntegerValueField(.scrollWheelEventDeltaAxis1)]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native secondary/scroll: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
