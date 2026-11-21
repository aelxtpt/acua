import Foundation
import CoreGraphics

@MainActor private final class World {
    typealias C=SettingsTransitionController<Int>
    struct Surface {
        var frames=[CGRect](),radii=[CGFloat](),progress=[CGFloat](),artwork=[Int?]()
        var closed=0
    }
    var surfaces=[Surface](),handlers=[(@MainActor (C.Event) -> Void)?]()
    var log=[String](),queued=[@MainActor @Sendable () -> Void]()
    var springs=[C.Spring]()
    var onStop: (@MainActor () -> Void)?
    func make() -> C {
        C(environment:.init(makeOverlay:{ [self] source,target in
            let i=surfaces.count;surfaces.append(.init());log.append("make:\(i):\(String(describing:source)):\(String(describing:target))")
            return .init(frame:{ [self] in surfaces[i].frames.append($0);log.append("frame:\(i)") },
                radius:{ [self] in surfaces[i].radii.append($0);log.append("radius:\(i)") },
                progress:{ [self] in surfaces[i].progress.append($0);log.append("progress:\(i)") },
                targetArtwork:{ [self] in surfaces[i].artwork.append($0);log.append("artwork:\(i)") },
                alpha:{ [self] in log.append("alpha:\(i):\($0)") },show:{ [self] in log.append("show:\(i)") },
                close:{ [self] in surfaces[i].closed += 1;log.append("close:\(i)") })
        },makeAnimation:{ [self] spring,_ in
            let i=handlers.count;handlers.append(nil);springs.append(spring);log.append("animation:\(i)")
            return .init(setHandler:{ [self] handler in handlers[i]=handler;log.append("handler:\(i):\(handler != nil)") },
                start:{ [self] in log.append("start:\(i)") },stopImmediately:{ [self] in log.append("stop:\(i)");onStop?() })
        },enqueueClose:{ [self] in queued.append($0);log.append("queue.close") }))
    }
    var source:C.Capture { .init(frameOnScreen:CGRect(x:0.25,y:0.5,width:99.5,height:59.25),artwork:1,cornerRadius:10) }
    var target:C.Capture { .init(frameOnScreen:CGRect(x:200.25,y:100.5,width:199.5,height:99.25),artwork:2,cornerRadius:30) }
}

@main private enum Tests {
    @MainActor static var rows=[[String:Any]]()
    @MainActor static func check(_ condition:Bool,_ name:String) {
        rows.append(["name":name,"passed":condition]);print("\(condition ? "PASS":"FAIL") \(name)")
    }
    @MainActor static func main() throws {
        do {
            let w=World(),c=w.make();c.start(from:w.source,to:w.target) { w.log.append("completion") }
            check(w.log == ["make:0:Optional(1):Optional(2)","frame:0","radius:0","progress:0","alpha:0:1.0","show:0","animation:0","handler:0:true","start:0"],"initial artwork/frame/radius/progress/show precede animation start")
            check(c.source?.frameOnScreen == CGRect(x:0,y:0,width:100,height:60) && c.target?.frameOnScreen == CGRect(x:200,y:100,width:200,height:100),"captures are integral before ticks")
            let spring=w.springs[0]
            check(spring.period == 0.72 && spring.dampingFraction == 1 && spring.initialValue == 0 && spring.targetValue == 1 && spring.idleVelocityThreshold == nil,"transition spring parameters and absent idle velocity threshold")
            w.handlers[0]?(.value(0.5))
            check(w.surfaces[0].frames.last == CGRect(x:100,y:160,width:150,height:80) && w.surfaces[0].radii.last == 20 && w.surfaces[0].progress.last == 0.5,"midpoint uses the expected interpolated geometry")
            let count=w.log.count;w.handlers[0]?(.other)
            check(w.log.count == count,"unhandled animation event has no effect")
            w.handlers[0]?(.value(1.5))
            check(w.surfaces[0].radii.last == 40 && w.surfaces[0].progress.last == 1.5,"spring overshoot preserves raw radius and progress")
            var target=w.target;target.frameOnScreen=CGRect(x:-12.5,y:40.5,width:2,height:3);target.artwork=nil;target.cornerRadius = -5
            let before=w.log.count;c.retarget(target)
            check(w.log.count == before+1 && w.log.last == "artwork:0" && w.handlers.count == 1 && c.target?.frameOnScreen == target.frameOnScreen.integral && w.surfaces[0].artwork.last! == nil,"retarget changes integral capture and optional target art without restart")
            w.handlers[0]?(.value(1))
            check(w.surfaces[0].frames.last == target.frameOnScreen.integral && w.surfaces[0].radii.last == -5,"next tick consumes latest target without radius clamp")
            let late=w.handlers[0]!;w.onStop={ check(w.handlers[0] == nil && c.animation == nil,"stop removes handler and animation reference before engine stop") }
            c.stop();w.onStop=nil
            check(c.source == nil && c.target == nil && c.overlay == nil && c.animation == nil && w.surfaces[0].closed == 1 && w.queued.isEmpty,"stop synchronously closes and clears without completion or queued close")
            let stopped=w.log.count;late(.value(0.2));c.stop()
            check(w.log.count == stopped && !w.log.contains("completion"),"late value after stop and repeated stop have no effect")
            late(.finished)
            check(w.queued.count == 1 && w.surfaces[0].closed == 1 && c.overlay == nil,"finish after stop still queues the nil-overlay close operation")
            w.queued.removeFirst()()
        }
        do {
            let w=World(),c=w.make();var observed=false
            c.start(from:w.source,to:w.target) {
                observed=c.source != nil && c.target != nil && c.overlay != nil && c.animation == nil && w.handlers[0] == nil && w.queued.isEmpty && w.surfaces[0].closed == 0
                w.log.append("completion")
            }
            let late=w.handlers[0]!;w.log=[];late(.finished)
            check(observed,"completion runs inline after final snap/handler detach and before capture/overlay cleanup")
            check(w.log == ["handler:0:false","frame:0","radius:0","artwork:0","progress:0","completion","queue.close"],"finish applies target frame/radius/artwork/progress then completion then queues close")
            check(c.source == nil && c.target == nil && c.overlay == nil && c.animation == nil && w.surfaces[0].closed == 0 && w.queued.count == 1,"completed overlay lives until queued close")
            w.queued.removeFirst()()
            check(w.surfaces[0].closed == 1,"queued finish closes retained old overlay")
            let count=w.log.count;late(.value(0.4))
            check(w.log.count == count,"finished transition ignores late value with absent captures")
        }
        do {
            let w=World(),c=w.make();c.start(from:w.source,to:w.target) { w.log.append("obsolete") }
            let old=w.handlers[0]!;var next=w.source;next.cornerRadius=100
            c.start(from:next,to:w.target) { w.log.append("current") }
            check(w.handlers[0] == nil && w.surfaces[0].closed == 1 && !w.log.contains("obsolete"),"replacement start stops and closes predecessor without its completion")
            old(.value(0))
            check(w.surfaces[0].radii.last == 100 && w.surfaces[1].radii.last == 100,"already captured old value callback uses current captures and captured old overlay")
            old(.finished)
            check(w.log.contains("current") && !w.log.contains("obsolete") && w.handlers[1] == nil && c.overlay == nil && w.queued.count == 1,"late old finish follows the shared current state without an identity filter")
            w.queued.removeFirst()()
            check(w.surfaces[1].closed == 1,"late old finish queues current overlay close")
        }
        do {
            let w=World(),c=w.make()
            c.start(from:w.source,to:w.target) { c.start(from:w.target,to:w.source) {} }
            w.handlers[0]?(.finished)
            check(w.handlers.count == 2 && w.handlers[1] != nil && c.animation != nil && c.source == nil && c.target == nil && c.overlay == nil,"finish callback reentrancy keeps post-callback shared clearing")
            check(w.surfaces[0].closed == 1 && w.surfaces[1].closed == 0 && w.queued.count == 1,"reentrant start closes old overlay synchronously; old finish queues retained old owner")
            w.queued.removeFirst()();c.stop()
            check(w.surfaces[0].closed == 2 && w.surfaces[1].closed == 0 && w.handlers[1] == nil,"reentrant finalization does not invent close for newly orphaned overlay")
        }
        do {
            let w=World(),c=w.make();var source=w.source,target=w.target
            source.cornerRadius=1e16;target.cornerRadius=0
            c.start(from:source,to:target) {}
            w.handlers[0]?(.value(CGFloat(1).nextUp))
            check(w.surfaces[0].radii.last == -2.220446049250313 && w.surfaces[0].radii.last != -2,"fused multiply-add radius retains cancellation precision at overshoot")
            c.stop()
        }
        do {
            let w=World();var controller:World.C?=w.make()
            controller!.start(from:w.source,to:w.target) {}
            let late=w.handlers[0]!;weak let weakController=controller;controller=nil
            let count=w.log.count;late(.value(0.5));late(.finished)
            check(weakController == nil && w.log.count == count,"animation callback weakly owns controller and ignores events after owner release")
        }
        let passed=rows.allSatisfy { $0["passed"] as? Bool == true }
        let result:[String:Any] = ["passed":passed,"cases":rows.count,"results":rows,"nativeWindowAnimationCaptureOrUIExecuted":false]
        if CommandLine.arguments.count > 1 { try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1])) }
        if !passed { exit(1) }
    }
}
