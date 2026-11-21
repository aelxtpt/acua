import AppKit

@MainActor private final class Link: SystemSettingsDisplayLinkObject {
    var timestamp=0.0,duration=1.0/60,targetTimestamp=1.0/60
    var adds=0,invalidations=0
    var onInvalidate:(()->Void)?
    weak var driver:SystemSettingsDisplayLinkDriver?
    func add(to runloop:RunLoop,forMode mode:RunLoop.Mode) { adds += 1 }
    func invalidate() { invalidations += 1;onInvalidate?() }
    func fire(_ time:Double) { timestamp=time;targetTimestamp=time+duration;driver?.displayLinkDidFire() }
}
@MainActor private final class World {
    typealias C=SettingsTransitionController<Int>
    struct Surface { var frame:CGRect = .zero;var radius:CGFloat=0;var progress:CGFloat=0;var artwork:Int?;var closed=0 }
    var surfaces=[Surface](),links=[Link](),drivers=[SystemSettingsDisplayLinkDriver]()
    var queued=[@MainActor @Sendable ()->Void](),log=[String]()
    func make()->C {
        C(environment:.init(makeOverlay:{ [self] source,target in
            let i=surfaces.count;surfaces.append(.init(artwork:target))
            return .init(frame:{ [self] in surfaces[i].frame=$0 },radius:{ [self] in surfaces[i].radius=$0 },progress:{ [self] in surfaces[i].progress=$0 },
                targetArtwork:{ [self] in surfaces[i].artwork=$0 },alpha:{ _ in },show:{},close:{ [self] in surfaces[i].closed += 1;log.append("close:\(i)") })
        },makeAnimation:{ [self] config,_ in
            let link=Link(),i=links.count
            let driver=SystemSettingsDisplayLinkDriver { target,_ in link.driver=target as? SystemSettingsDisplayLinkDriver;return link }
            link.onInvalidate={ [weak self] in self?.log.append("invalidate:\(i)") }
            links.append(link);drivers.append(driver)
            return SystemSettingsTransitionAnimationBinding<Int>.make(configuration:config,driver:driver)
        },enqueueClose:{ [self] in queued.append($0) }))
    }
    var source:C.Capture { .init(frameOnScreen:CGRect(x:0,y:0,width:100,height:60),artwork:1,cornerRadius:24) }
    var target:C.Capture { .init(frameOnScreen:CGRect(x:200,y:100,width:200,height:100),artwork:2,cornerRadius:14) }
}
@main struct BindingChecks {
    @MainActor static func main() throws {
        var rows=[[String:Any]]()
        func check(_ ok:Bool,_ label:String) { rows.append(["name":label,"passed":ok]);precondition(ok,label);print("PASS \(label)") }
        do {
            let w=World(),c=w.make();var done=0,visibleBeforeClose=false,activeAtCompletion=false
            c.start(from:w.source,to:w.target) {
                done += 1;visibleBeforeClose=w.surfaces[0].closed==0 && w.queued.isEmpty
                activeAtCompletion=w.drivers[0].isActive;w.log.append("completion")
            }
            check(w.links.count==1 && w.links[0].adds==1 && w.drivers[0].isActive,"controller starts the production spring/display registration once")
            w.links[0].fire(0)
            check(w.surfaces[0].progress>0 && w.surfaces[0].progress<1,"real production spring advances the replica through the driver callback")
            var target=w.target;target.frameOnScreen=CGRect(x:-120.5,y:70.25,width:90,height:30);target.cornerRadius = -5;target.artwork=nil
            c.retarget(target)
            check(w.links.count==1 && w.links[0].adds==1 && w.surfaces[0].artwork==nil,"full retarget publishes absent artwork without a new driver")
            for i in 1...180 where done==0 { w.links[0].fire(Double(i)/60) }
            check(done==1 && c.animation==nil && c.overlay==nil,"real spring natural completion clears current controller state once")
            check(visibleBeforeClose && activeAtCompletion,"completion occurs before driver invalidation and deferred overlay close")
            check(w.surfaces[0].frame==target.frameOnScreen.integral && w.surfaces[0].radius == -5 && w.surfaces[0].progress==1,"completion snaps the latest frame and raw radius")
            check(w.links[0].invalidations==1 && !w.drivers[0].isActive && w.queued.count==1,"finished spring unregisters its actual driver while close remains queued")
            w.queued.removeFirst()()
            check(w.log == ["completion","invalidate:0","close:0"],"native binding preserves completion then invalidation then queued close order")
            let log=w.log;w.links[0].fire(8)
            check(w.log==log && done==1,"an obsolete display callback cannot redeliver completion")
        }
        do {
            let w=World(),c=w.make();var done=0
            c.start(from:w.source,to:w.target) { done += 1 };w.links[0].fire(0);c.stop()
            check(done==0 && w.surfaces[0].closed==1 && w.links[0].invalidations==1 && !w.drivers[0].isActive,"explicit stop detaches completion and synchronously stops the real registration")
            w.links[0].fire(1);c.stop()
            check(done==0 && w.links[0].invalidations==1 && w.queued.isEmpty,"repeated cancel and late callback have no side effects")
            c.start(from:w.target,to:w.source) { done += 1 }
            check(w.links.count==2 && w.links[1].adds==1 && w.drivers[1].isActive,"replacement starts a new source driver instead of restarting an invalidated link")
            c.stop()
        }
        do {
            let w=World(),c=w.make();var source=w.source;source.artwork=nil
            c.start(from:source,to:w.target) { c.start(from:w.target,to:source) {} }
            for i in 0...180 where w.links.count==1 { w.links[0].fire(Double(i)/60) }
            check(w.links.count==2 && w.links[0].invalidations==1 && w.links[1].invalidations==0,"reentrant completion closes only the finished driver registration")
            check(c.animation != nil && c.source==nil && c.target==nil && c.overlay==nil,"production binding keeps reentrant shared-state clearing")
            w.queued.removeFirst()();c.stop()
            check(w.links[1].invalidations==1 && w.surfaces[0].closed==2 && w.surfaces[1].closed==0,"cleanup keeps orphan-overlay behavior while stopping the new registration")
        }
        let result:[String:Any]=["passed":true,"cases":rows.count,"results":rows,"actualProductionSpringControllerAndDriverBindingExecuted":true,"nativeDisplayLinkWindowInputCaptureExecuted":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
    }
}
