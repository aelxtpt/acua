import AppKit
import ApplicationServices

@main enum EventStreamChildrenNativeTests {
    @MainActor static var checks = 0
    @MainActor static var failures = 0
    @MainActor static func check(_ name: String, _ result: @autoclosure () -> Bool) {
        if result() {checks += 1;print("PASS: \(name)")}
        else {failures += 1;print("FAIL: \(name)")}
    }
    @MainActor static func fixture() {
        let app = NSApplication.shared;app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect:.init(x:100,y:100,width:640,height:600),styleMask:[.titled],backing:.buffered,defer:false)
        window.title = "Disposable EventStream child collection";window.isReleasedWhenClosed=false
        var groups: [NSView] = []
        for (key,count,y) in [("small",3,400),("large",140,200),("huge",500,0)] {
            let group = NSView(frame:.init(x:10,y:y,width:600,height:170))
            group.setAccessibilityElement(true);group.setAccessibilityRole(.group)
            group.setAccessibilityIdentifier("child-group-"+key)
            var fields: [NSTextField] = []
            for i in 0..<count {
                let row: Int
                if i < 3 { row = i }
                else if i >= 70 && i < 73 { row = i-67 }
                else { row = i+20 }
                let field = NSTextField(labelWithString:"\(key) child \(i)")
                field.frame = .init(x:10,y:10+row*25,width:180,height:20)
                field.setAccessibilityIdentifier("\(key)-\(i)")
                group.addSubview(field);fields.append(field)
            }
            group.setAccessibilityChildren(fields)
            if key == "large" { group.setAccessibilityVisibleChildren([fields[70],fields[71]]) }
            window.contentView!.addSubview(group);groups.append(group)
        }
        window.orderBack(nil);app.finishLaunching()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
            let frames = groups.map { view -> [String:Any] in
                let frame = view.accessibilityFrame()
                // AppKit exposes bottom-origin screen coordinates; the AX
                // bridge flips to the primary screen's top-origin coordinates.
                let top = NSScreen.screens.first!.frame.maxY
                return ["identifier":view.accessibilityIdentifier(),"x":frame.minX,"y":top-frame.maxY,"width":frame.width,"height":frame.height]
            }
            let data = try! JSONSerialization.data(withJSONObject:["pid":getpid(),"window":window.windowNumber,"frames":frames])
            FileHandle.standardOutput.write(data+Data([10]))
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+60) {app.terminate(nil)}
        withExtendedLifetime((window,groups)) { app.run() }
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.contains("--fixture") { fixture();return }
        guard AXIsProcessTrusted(), (CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            fputs("Native child collection requires an unlocked macOS session and Accessibility.\n",stderr);exit(2)
        }
        let child = Process(), pipe = Pipe()
        child.executableURL = .init(fileURLWithPath:CommandLine.arguments[0]);child.arguments=["--fixture"]
        child.standardOutput=pipe;child.standardError=FileHandle.standardError;try child.run()
        let watchdog = DispatchWorkItem { if child.isRunning {child.terminate()} }
        DispatchQueue.global().asyncAfter(deadline:.now()+20,execute:watchdog)
        defer { watchdog.cancel();if child.isRunning {child.terminate()};child.waitUntilExit() }
        let ready = try JSONSerialization.jsonObject(with:pipe.fileHandleForReading.availableData) as! [String:Any]
        let pid = (ready["pid"] as! NSNumber).int32Value
        let application = EventStreamAXNode(AXUIElementCreateApplication(pid))
        func nodes(_ node: EventStreamAXNode, _ key: String) -> [EventStreamAXNode] {
            guard let value = node.attribute(key) as? [AnyObject] else { return [] }
            return value.compactMap { raw in
                guard CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
                return .init(unsafeBitCast(raw,to:AXUIElement.self))
            }
        }
        var queue=nodes(application,"AXWindows"),index=0,found:[String:EventStreamAXNode]=[:]
        while index<queue.count && index<30 && found.count<3 {
            let node=queue[index];index += 1
            if let id=node.attribute("AXIdentifier") as? String, id.hasPrefix("child-group-") {found[id]=node;continue}
            queue.append(contentsOf:nodes(node,"AXChildren"))
        }
        check("external native AX lookup locates all three owned containers",found.count==3)
        guard found.count==3 else {throw NSError(domain:"NativeChildrenFixture",code:1)}
        let small = EventStreamNativeChildren(parent:found["child-group-small"]!)
        let large = EventStreamNativeChildren(parent:found["child-group-large"]!)
        let huge = EventStreamNativeChildren(parent:found["child-group-huge"]!)
        func ids(_ values: [EventStreamAXNode]?) -> [String] { values?.compactMap { $0.attribute("AXIdentifier") as? String } ?? [] }
        check("native child counts come from actual AX arrays",small.count("AXChildren")==3 && large.count("AXChildren")==140 && huge.count("AXChildren")==500)
        let smallResult = EventStreamChildren(backend:small).collect(contextKind:1,isWebShaped:false)
        check("ordinary native child read preserves original order",ids(smallResult?.elements)==["small-0","small-1","small-2"] && smallResult?.subset==nil)
        let largeFrame = (ready["frames"] as! [[String:Any]]).first { $0["identifier"] as? String == "child-group-large" }!
        let expected = CGRect(x:(largeFrame["x"] as! NSNumber).doubleValue,y:(largeFrame["y"] as! NSNumber).doubleValue,width:(largeFrame["width"] as! NSNumber).doubleValue,height:(largeFrame["height"] as! NSNumber).doubleValue)
        check("native parent frame agrees with independently converted AppKit frame",large.frame()==expected)
        check("native supported attributes expose explicit visible children",large.supportedAttributes().contains("AXVisibleChildren") && large.count("AXVisibleChildren")==2)
        let nativeVisible = EventStreamChildren(backend:large).collect(contextKind:1,isWebShaped:false)
        check("native visible children map back to full source positions",ids(nativeVisible?.elements)==["large-70","large-71"] && nativeVisible?.subset == .init(count:140,availableRanges:[70..<72]))
        let allPosition = EventStreamChildren(backend:large).collect(contextKind:1,isWebShaped:true)
        check("web-shaped native path selects all geometric runs",ids(allPosition?.elements)==["large-0","large-1","large-2","large-70","large-71","large-72"] && allPosition?.subset == .init(count:140,availableRanges:[0..<3,70..<73]))
        let position = EventStreamChildren(backend:large).byPosition(maximum:100,includeAllRanges:false,clippingFrame:nil)
        check("native position fallback picks later tie and surrounding100",ids(position?.elements)==(21..<121).map {"large-\($0)"} && position?.subset == .init(count:140,availableRanges:[21..<121]))
        check("web count500 gate rejects an actual oversized container",EventStreamChildren(backend:huge).collect(contextKind:1,isWebShaped:true)==nil)
        let allHuge = EventStreamChildren(backend:huge).collect(threshold:500,contextKind:0,isWebShaped:false)
        check("normal explicit threshold can read actual500-element array",allHuge?.elements.count==500 && ids(allHuge?.elements).last=="huge-499" && allHuge?.subset==nil)
        if let first=smallResult?.elements.first {
            check("native cached child list retains AX reference equality",small.cachedArray("AXChildren").map {small.equal($0[0],first)} == true)
        }
        let fresh = EventStreamNativeChildren(parent:EventStreamAXNode(large.parent.element))
        check("uncached provider starts without borrowed array snapshot",fresh.cachedArray("AXChildren")==nil)
        child.terminate();child.waitUntilExit()
        check("fresh provider returns no children after owned app exits",EventStreamChildren(backend:fresh).collect(contextKind:1,isWebShaped:false)==nil)
        print("EVENT STREAM NATIVE CHILD COLLECTION: \(checks) checks passed")
        guard failures==0 else {throw NSError(domain:"NativeChildrenFixture",code:failures)}
    }
}
