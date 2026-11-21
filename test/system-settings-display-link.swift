import AppKit
import QuartzCore

@MainActor private final class Link: SystemSettingsDisplayLinkObject {
    var log=[String](),frames=[SystemSettingsAnimationFrame]()
    var onTimestamp:(()->Void)?,onAdd:(()->Void)?,onInvalidate:(()->Void)?
    var target:AnyObject?
    var current=SystemSettingsAnimationFrame(timestamp:2,duration:0.01,targetTimestamp:2.02)
    var timestamp:CFTimeInterval { log.append("timestamp");onTimestamp?();return current.timestamp }
    var duration:CFTimeInterval { log.append("duration");return current.duration }
    var targetTimestamp:CFTimeInterval { log.append("targetTimestamp");return current.targetTimestamp }
    var adds=0,invalidations=0,invalidated=false
    var lastRunLoop:RunLoop?,lastMode:RunLoop.Mode?
    func add(to runloop:RunLoop,forMode mode:RunLoop.Mode) { log.append("add");adds += 1;lastRunLoop=runloop;lastMode=mode;onAdd?() }
    func invalidate() { log.append("invalidate");invalidations += 1;invalidated=true;target=nil;onInvalidate?() }
}
private final class Box: @unchecked Sendable {
    private let lock=NSLock()
    private var object:SystemSettingsDisplayLinkDriver?
    init(_ object:SystemSettingsDisplayLinkDriver) { self.object=object }
    func release() { lock.withLock { object=nil } }
}
@main private enum Tests {
    @MainActor static var rows=[[String:Any]]()
    @MainActor static func check(_ ok:Bool,_ name:String) { rows.append(["name":name,"passed":ok]);print("\(ok ? "PASS":"FAIL") \(name)") }
    @MainActor static func main() async throws {
        do {
            let link=Link();var selector="",factories=0
            let driver=SystemSettingsDisplayLinkDriver { target,sel in link.target=target;selector=NSStringFromSelector(sel);factories += 1;return link }
            check(link.target === driver && selector == "displayLinkDidFire" && factories==1 && !driver.isActive,"factory receives actual driver and the zero-argument selector")
            driver.displayLinkDidFire();check(link.log.isEmpty,"absent callback avoids all display-link reads")
            link.onAdd={ check(driver.isActive,"active flag is set before native add") }
            driver.start();link.onAdd=nil
            check(link.adds==1 && link.lastRunLoop === RunLoop.current && link.lastMode == .common,"start adds to current runloop/common modes")
            driver.start();check(link.adds==1,"repeated active start does not add again")
            driver.frameCallback={ frame in link.frames.append(frame);link.log.append("callback") }
            link.log=[];driver.displayLinkDidFire()
            check(link.log == ["timestamp","duration","targetTimestamp","callback"] && link.frames == [link.current],"frame reads keep their order and raw values")
            link.onInvalidate={ check(!driver.isActive,"active flag is cleared before invalidate") }
            driver.stop();link.onInvalidate=nil
            check(!driver.isActive && link.invalidations==1 && link.target == nil,"stop invalidates and permits target release")
            driver.stop();check(link.invalidations==1,"repeated inactive stop is inert")
            driver.displayLinkDidFire();check(link.frames.count==2,"already delivered callback is not suppressed by an invented active check")
            driver.start();check(driver.isActive && factories==1 && link.adds==2 && link.invalidated,"restart uses same invalidated native object without recreation")
            driver.stop();driver.frameCallback=nil
        }
        do {
            let link=Link(),driver=SystemSettingsDisplayLinkDriver { _,_ in link }
            link.onAdd={ driver.stop() };driver.start();link.onAdd=nil
            check(!driver.isActive && link.log == ["add","invalidate"],"reentrant stop during add is preserved")
            driver.start();link.onInvalidate={ driver.start() };driver.stop();link.onInvalidate=nil
            check(driver.isActive && link.adds==3,"reentrant start during invalidate is not overwritten")
            driver.stop()
        }
        do {
            let link=Link(),driver=SystemSettingsDisplayLinkDriver { _,_ in link }
            var old=0,new=0
            driver.frameCallback={ _ in old += 1 }
            link.onTimestamp={ driver.frameCallback={ _ in new += 1 };driver.stop() }
            driver.start();driver.displayLinkDidFire();link.onTimestamp=nil
            check(old==1 && new==0 && link.log.suffix(2)==["duration","targetTimestamp"],"callback capture precedes getter reentrancy")
            driver.displayLinkDidFire();check(new==1,"replacement handler is used on following delivery")
            link.current = .init(timestamp:.nan,duration:-1,targetTimestamp:.infinity)
            driver.frameCallback={ frame in check(frame.timestamp.isNaN && frame.duration == -1 && frame.targetTimestamp == .infinity,"driver forwards non-finite and negative raw timing without normalization") }
            driver.displayLinkDidFire();driver.frameCallback=nil
        }
        do {
            let link=Link();var driver:SystemSettingsDisplayLinkDriver?=SystemSettingsDisplayLinkDriver { target,_ in link.target=target;return link }
            weak let weakDriver=driver;driver!.start();driver=nil
            check(weakDriver != nil,"owned retained-target fixture keeps driver alive until invalidation")
            (link.target as! SystemSettingsDisplayLinkDriver).stop()
            check(weakDriver == nil && link.invalidations==1,"stop breaks owned target cycle and inactive deinit adds no invalidation")
        }
        do {
            let link=Link();var driver:SystemSettingsDisplayLinkDriver?=SystemSettingsDisplayLinkDriver { _,_ in link }
            driver!.start();driver=nil
            check(link.invalidations==1 && Thread.isMainThread,"active deinit method body invalidates on main actor with nonretaining owned link")
        }
        do {
            let link=Link();var driver:SystemSettingsDisplayLinkDriver?=SystemSettingsDisplayLinkDriver { _,_ in link }
            driver!.start();let box=Box(driver!);driver=nil
            await Task.detached { box.release() }.value
            for _ in 0..<1000 where link.invalidations==0 { await Task.yield() }
            check(link.invalidations==1 && Thread.isMainThread,"off-actor final release schedules isolated native cleanup on main actor")
        }
        do {
            let link=Link(),driver=SystemSettingsDisplayLinkDriver { target,_ in link.target=target;return link }
            let animation=SystemSettingsSpringAnimation()
            var binding:SystemSettingsSpringDriverBinding? = .init(animation:animation,driver:driver)
            var values=[Double](),finished=0
            animation.eventHandler={ event in
                switch event { case .valueChanged(_,let value):values.append(value);case .finished:finished += 1;case .targetChanged:break }
            }
            binding!.start();binding!.start()
            weak let weakBinding=binding;binding=nil
            check(weakBinding != nil && driver.isActive && link.adds==1,"active registration retains animation independently of permission UI owner")
            link.current = .init(timestamp:0,duration:1.0/60,targetTimestamp:1.0/60);driver.displayLinkDidFire()
            check(values.first == 0.007546663498336072 && animation.state == .running,"actual driver/model binding predicts the expected first displayed frame")
            for i in 1...40 where driver.isActive {
                link.current = .init(timestamp:Double(i)/30,duration:1.0/60,targetTimestamp:Double(i)/30+1.0/60);driver.displayLinkDidFire()
            }
            check(finished==1 && animation.value==1 && animation.state == .finished,"actual driver/model binding completes the animation")
            check(!driver.isActive && driver.frameCallback == nil && link.invalidations==1 && weakBinding == nil,"completed row releases registration/callback and invalidates native source")
            animation.eventHandler=nil
        }
        do {
            let link=Link(),driver=SystemSettingsDisplayLinkDriver { _,_ in link },animation=SystemSettingsSpringAnimation()
            let binding=SystemSettingsSpringDriverBinding(animation:animation,driver:driver);var finished=0
            animation.eventHandler={ if case .finished=$0 { finished += 1 } }
            binding.start();let late=driver.frameCallback!
            binding.cancel();binding.cancel()
            check(!binding.isRegistered && !driver.isActive && link.invalidations==1 && finished==0 && animation.state == .finished,"cancellation clears completion before immediate stop and removes owned row once")
            let before=animation.simulation.time;late(.init(timestamp:100,duration:1,targetTimestamp:101))
            check(animation.simulation.time==before && animation.state == .finished,"in-flight driver callback cannot process a removed registration")
        }
        let passed=rows.allSatisfy { $0["passed"] as? Bool == true }
        let result:[String:Any] = ["passed":passed,"cases":rows.count,"results":rows,"actualDisplayLinkCreated":false,"nativeWindowOrInputExecuted":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        if !passed { exit(1) }
    }
}
