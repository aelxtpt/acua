import AppKit
import ApplicationServices

private final class MonitorFixturePanel:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}

private final class NativeCallbackState:@unchecked Sendable {
    private let lock=NSLock()
    private var count=0,workerDelivery=false
    private var payload:EventStreamAXNotificationEvent?
    func receive(_ event:EventStreamAXNotificationEvent?=nil) {
        lock.lock();defer {lock.unlock()}
        count += 1;workerDelivery = !Thread.isMainThread && Thread.current.qualityOfService == .utility
        if let event {payload=event}
    }
    var snapshot:(count:Int,workerDelivery:Bool) {lock.lock();defer {lock.unlock()};return (count,workerDelivery)}
    var lastEvent:EventStreamAXNotificationEvent? {lock.lock();defer {lock.unlock()};return payload}
}
private final class WeakNativeObserver {
    weak var value:EventStreamNativeAXObserver?
    init(_ value:EventStreamNativeAXObserver?) {self.value=value}
}

@main enum InvalidationMonitorNativeTests {
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ condition:@autoclosure()->Bool) {
        guard condition() else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    @MainActor static func fixture() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let window=MonitorFixturePanel(contentRect:.init(x:100,y:100,width:400,height:180),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false)
        window.hidesOnDeactivate=false
        window.title="Disposable EventStream Invalidation Monitor";window.isReleasedWhenClosed=false
        let button=NSButton(title:"Transient monitored button",target:nil,action:nil)
        button.frame = .init(x:30,y:70,width:260,height:35)
        button.setAccessibilityIdentifier("monitor-transient-button");window.contentView!.addSubview(button)
        window.orderBack(nil);app.finishLaunching()
        FileHandle.standardInput.readabilityHandler={handle in
            let data=handle.availableData
            guard !data.isEmpty else {handle.readabilityHandler=nil;return}
            let commands=String(decoding:data,as:UTF8.self).split(separator:"\n").map(String.init)
            DispatchQueue.main.async {
                for command in commands {
                    if command=="layout" {NSAccessibility.post(element:window,notification:.layoutChanged)}
                    if command=="destroy" {
                        NSAccessibility.post(element:button,notification:.uiElementDestroyed)
                        button.removeFromSuperview()
                    }
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
            FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject:["pid":getpid(),"isKeyWindow":window.isKeyWindow])+Data([10]))
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+40) {app.terminate(nil)}
        withExtendedLifetime((window,button)) {app.run()}
    }
    @MainActor static func wait(_ condition:()->Bool) async throws {
        let deadline=ProcessInfo.processInfo.systemUptime+3
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime<deadline else {throw NSError(domain:"NativeInvalidationMonitorTimeout",code:1)}
            try await Task.sleep(nanoseconds:10_000_000)
        }
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.contains("--fixture") {fixture();return}
        let accessibilityTrusted=AXIsProcessTrusted()
        let sessionLocked=(CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        guard accessibilityTrusted,!sessionLocked else {
            fputs("Native monitor tests require unlocked macOS and Accessibility: accessibility=\(accessibilityTrusted), locked=\(sessionLocked).\n",stderr);exit(2)
        }
        let child=Process(),output=Pipe(),control=Pipe()
        child.executableURL = .init(fileURLWithPath:CommandLine.arguments[0]);child.arguments=["--fixture"]
        child.standardOutput=output;child.standardInput=control;child.standardError=FileHandle.standardError;try child.run()
        let watchdog=DispatchWorkItem {if child.isRunning {child.terminate()}}
        DispatchQueue.global().asyncAfter(deadline:.now()+30,execute:watchdog)
        defer {watchdog.cancel();if child.isRunning {child.terminate()};child.waitUntilExit()}
        let ready=try JSONSerialization.jsonObject(with:output.fileHandleForReading.availableData) as! [String:Any]
        check("owned monitor fixture cannot receive keyboard focus",ready["isKeyWindow"] as? Bool == false)
        let pid=(ready["pid"] as! NSNumber).int32Value,app=AXUIElementCreateApplication(pid)
        func raw(_ element:AXUIElement,_ name:String)->AnyObject? {
            var value:CFTypeRef?;return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value:nil
        }
        func children(_ raw:AnyObject?)->[AXUIElement] {
            (raw as? [AnyObject] ?? []).compactMap {CFGetTypeID($0)==AXUIElementGetTypeID() ? unsafeBitCast($0,to:AXUIElement.self):nil}
        }
        var pending=children(raw(app,"AXWindows")),button:AXUIElement?,position=0
        while position<pending.count && position<100 {
            let next=pending[position];position += 1
            if raw(next,"AXIdentifier") as? String == "monitor-transient-button" {button=next;break}
            pending.append(contentsOf:children(raw(next,"AXChildren")))
        }
        guard let button else {throw NSError(domain:"NativeInvalidationMonitorFixtureMissing",code:1)}
        check("external fixture exposes the transient accessible button",raw(button,"AXRole") as? String == "AXButton")
        var monitor:EventStreamTreeInvalidationMonitor? = .init(application:app)
        check("real application monitor registers and starts its observer",monitor!.hasObserver)
        check("real monitor begins without synthesized invalidations",monitor!.state == .init())
        // Drain the worker's main-queue configuration barrier.
        try await Task.sleep(nanoseconds:150_000_000)
        try control.fileHandleForWriting.write(contentsOf:Data("layout\n".utf8))
        try await wait {monitor!.state.layoutChanged}
        check("actual AppKit layout notification reaches dedicated worker",monitor!.state.layoutChanged && monitor!.state.destroyedElements.isEmpty)
        monitor!.withState {$0.layoutChanged=false}
        try control.fileHandleForWriting.write(contentsOf:Data("layout\nlayout\n".utf8))
        try await wait {monitor!.state.layoutChanged}
        check("reset consumer observes later actual layout notifications",monitor!.state.layoutChanged)
        try control.fileHandleForWriting.write(contentsOf:Data("destroy\n".utf8))
        try await wait {monitor!.state.destroyedElements.contains(.init(element:button))}
        check("actual destroyed notification retains exact prior native identity",monitor!.state.destroyedElements.contains(.init(element:button)))
        check("destruction accumulation preserves the existing layout bit",monitor!.state.layoutChanged)
        monitor=nil
        // The wrapper is explicitly released while its app remains alive.
        let absent=EventStreamTreeInvalidationMonitor(application:AXUIElementCreateApplication(-123456))
        check("nonexistent process leaves an inert readable native monitor",!absent.hasObserver && absent.state == .init())
        let deliveries=NativeCallbackState()
        var restarted:EventStreamNativeAXObserver?=try EventStreamNativeAXObserver(pid:pid,onNotification:{deliveries.receive($0)})
        try restarted!.register(kAXLayoutChangedNotification,for:app)
        try restarted!.register(kAXLayoutChangedNotification,for:app)
        check("actual duplicate registration is accepted",true)
        restarted!.start();restarted!.start();restarted!.stop();restarted!.stop();restarted!.start()
        try await Task.sleep(nanoseconds:150_000_000)
        try control.fileHandleForWriting.write(contentsOf:Data("layout\n".utf8))
        try await wait {deliveries.snapshot.count>0}
        check("restarted observer delivers actual notifications on Utility worker",deliveries.snapshot.workerDelivery)
        let payload=deliveries.lastEvent!
        check("actual callback retains observer and notification name",CFGetTypeID(payload.observer)==AXObserverGetTypeID() && payload.notification==kAXLayoutChangedNotification)
        var elementPID:pid_t = -1
        let elementStatus=AXUIElementGetPid(payload.element,&elementPID)
        check("actual callback element belongs to the disposable external fixture",elementStatus == .success && elementPID==pid && raw(payload.element,"AXRole") as? String == "AXWindow")
        restarted!.stop()
        try await Task.sleep(nanoseconds:50_000_000)
        let stoppedCount=deliveries.snapshot.count
        try control.fileHandleForWriting.write(contentsOf:Data("layout\n".utf8))
        try await Task.sleep(nanoseconds:100_000_000)
        check("stopped actual observer no longer delivers new fixture events",deliveries.snapshot.count==stoppedCount)
        let releasedWrapper=WeakNativeObserver(restarted)
        restarted=nil
        check("saved native event does not retain its observer wrapper",releasedWrapper.value==nil && CFGetTypeID(payload.observer)==AXObserverGetTypeID())
        print("EVENT STREAM NATIVE INVALIDATION MONITOR: \(checks) checks passed")
    }
}
