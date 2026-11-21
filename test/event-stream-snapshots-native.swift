import AppKit
import ApplicationServices

private final class SnapshotFixturePanel:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}

@main enum EventStreamNativeSnapshotTests {
    @MainActor static var checks=0,failures=0
    @MainActor static func check(_ label:String,_ result:@autoclosure () -> Bool) {
        if result() {checks += 1;print("PASS: \(label)")}
        else {failures += 1;print("FAIL: \(label)")}
    }
    @MainActor static func fixture(_ directory:URL) {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let window=SnapshotFixturePanel(contentRect:.init(x:100,y:100,width:420,height:180),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false)
        window.hidesOnDeactivate=false
        window.title="Disposable EventStream Snapshot";window.isReleasedWhenClosed=false
        let field=NSTextField(frame:.init(x:20,y:70,width:360,height:28))
        field.stringValue="snapshot-before";field.setAccessibilityIdentifier("snapshot-field")
        window.contentView!.addSubview(field)
        let timer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { _ in
            let command=directory.appendingPathComponent("command")
            guard (try? String(contentsOf:command,encoding:.utf8)) == "change" else {return}
            try? FileManager.default.removeItem(at:command)
            field.stringValue="snapshot-after"
            try! "changed".write(to:directory.appendingPathComponent("state"),atomically:true,encoding:.utf8)
        }
        window.orderBack(nil);app.finishLaunching()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
            let data=try! JSONSerialization.data(withJSONObject:["pid":getpid(),"window":window.windowNumber,"isKeyWindow":window.isKeyWindow,"initialValue":field.stringValue])
            FileHandle.standardOutput.write(data+Data([10]))
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+60) {app.terminate(nil)}
        withExtendedLifetime((window,field,timer)) {app.run()}
    }
    @MainActor static func main() throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.count==3,CommandLine.arguments[1]=="--fixture" {
            fixture(.init(fileURLWithPath:CommandLine.arguments[2]));return
        }
        guard AXIsProcessTrusted(),(CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool != true else {
            fputs("Native snapshots require an unlocked macOS session and Accessibility.\n",stderr);exit(2)
        }
        guard EventStreamHierarchySPI.available else {fputs("Native hierarchy SPI unavailable.\n",stderr);exit(3)}
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("cua-native-snapshots-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let child=Process(),pipe=Pipe();child.executableURL = .init(fileURLWithPath:CommandLine.arguments[0])
        child.arguments=["--fixture",directory.path];child.standardOutput=pipe;child.standardError=FileHandle.standardError
        try child.run()
        let watchdog=DispatchWorkItem {if child.isRunning {child.terminate()}}
        DispatchQueue.global().asyncAfter(deadline:.now()+20,execute:watchdog)
        defer {watchdog.cancel();if child.isRunning {child.terminate()};child.waitUntilExit()}
        let ready=try JSONSerialization.jsonObject(with:pipe.fileHandleForReading.availableData) as! [String:Any]
        let pid=(ready["pid"] as! NSNumber).int32Value
        guard ready["isKeyWindow"] as? Bool == false,ready["initialValue"] as? String == "snapshot-before" else {
            throw NSError(domain:"NativeSnapshotFixtureReadiness",code:1,userInfo:[NSLocalizedDescriptionKey:"The owned read-only fixture must retain its initial text without becoming a key window"])
        }
        func raw(_ element:AXUIElement,_ name:String) -> AnyObject? {
            var value:CFTypeRef?;return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value:nil
        }
        func elements(_ value:AnyObject?) -> [AXUIElement] {
            guard let values=value as? [AnyObject] else {return []}
            return values.compactMap {CFGetTypeID($0)==AXUIElementGetTypeID() ? unsafeBitCast($0,to:AXUIElement.self):nil}
        }
        let application=AXUIElementCreateApplication(pid)
        let windows=elements(raw(application,"AXWindows"))
        guard let fixtureWindow=windows.first else {throw NSError(domain:"NativeSnapshotFixture",code:3)}
        var queue=windows,index=0,field:AXUIElement?
        while index<queue.count && index<50 {
            let item=queue[index];index += 1
            if raw(item,"AXIdentifier") as? String == "snapshot-field" {field=item;break}
            queue.append(contentsOf:elements(raw(item,"AXChildren")))
        }
        guard let field else {throw NSError(domain:"NativeSnapshotFixture",code:1)}
        // Establish the external AX baseline before beginning the transaction.
        // A fixed launch delay does not establish that AppKit has published its
        // initial value; a failed first batch is deliberately cached by design.
        let readyDeadline=Date().addingTimeInterval(3)
        while raw(field,"AXRole") as? String != "AXTextField" || raw(field,"AXValue") as? String != "snapshot-before" {
            guard Date()<readyDeadline else {throw NSError(domain:"NativeSnapshotFixtureReadiness",code:2,
                userInfo:[NSLocalizedDescriptionKey:"Initial AX value was not published: \(String(describing:raw(field,"AXValue")))"]) }
            Thread.sleep(forTimeInterval:0.01)
        }
        let reader=EventStreamNativeSnapshots(),identity=EventStreamSnapshotAXIdentity(element:field)
        let transaction=EventStreamNativeSnapshots.Transaction()
        let before=reader.capture(field,transaction:transaction)
        check("native batch captures actual AX role and editable value",before.attributes["AXRole"] as? String == "AXTextField" && before.attributes["AXValue"] as? String == "snapshot-before")
        check("native supported set includes actual identifier and value",before.supportedAttributes.contains("AXIdentifier") && before.supportedAttributes.contains("AXValue"))
        check("native batch fields are selected from advertised attributes",Set(before.attributes.keys).isSubset(of:EventStreamSnapshotAttributes.selected(from:before.supportedAttributes){nil}))
        check("native fallback snapshot has no transaction marker",before.transactionAttributes==nil)
        let cachedNode=reader.node(field,transaction:transaction)
        check("native node descriptor consumes batched snapshot",EventStreamAXContext.reader().describe(cachedNode).value=="snapshot-before" && cachedNode.cachedAttribute("AXIdentifier") as? String == "snapshot-field")
        let constructedValue=EventStreamNativeValue.construct(cachedNode)
        check("native transformed value preserves actual field value and type",constructedValue.value=="snapshot-before" && constructedValue.kind == .string && constructedValue.truncationRange==nil)
        check("native transformed value queries editable field settability",constructedValue.isSettable)
        let constructedNode=EventStreamNativeNode.construct(cachedNode,context:.init(kind:1))
        check("native transformed node captures field role value and identifier",constructedNode.role=="AXTextField" && constructedNode.value=="snapshot-before" && constructedNode.stringValue=="snapshot-before" && constructedNode.identifier=="snapshot-field")
        check("native transformed node infers event-context focus and editing",constructedNode.isFocusable && constructedNode.isValueSettable && constructedNode.actionDescriptions.isEmpty)
        check("native transformed node retains original snapshot element",constructedNode.element === cachedNode)
        let collectedTree=EventStreamNativeTransactions(snapshots:reader).withSubtree(EventStreamAXNode(fixtureWindow)) {root in
            let result=EventStreamNativeTreeCollection.collect(root,context:.init(kind:1))
            if result.roots.first?.node.role != "AXWindow" || !result.preorder.contains(where:{$0.node.identifier=="snapshot-field"}) {
                print("DIAGNOSTIC native window raw role=\(String(describing:raw(fixtureWindow,"AXRole"))) captured=\(root.cachedAttributesSnapshot()) transaction=\(String(describing:root.transactionAttributes))")
                print("DIAGNOSTIC native collected nodes=\(result.preorder.map {($0.path,$0.node.role,$0.node.identifier,$0.node.value)})")
                print("DIAGNOSTIC hierarchy entries=\(EventStreamTreeTransactions.current?.snapshots.attributeTable.count ?? -1)")
            }
            return result
        }
        let collectedField=collectedTree.preorder.first {$0.node.identifier=="snapshot-field"}
        check("native collection starts at actual fixture window",collectedTree.roots.first?.node.role=="AXWindow")
        check("native collection reaches external field and captured value",collectedField?.node.value=="snapshot-before")
        check("native collection keeps field identity and descendant path",collectedField.map {CFEqual($0.node.element.element,field) && !$0.path.isEmpty}==true)
        var transformationContext=EventStreamMacTransformationContext(type:.eventStreamContext,
            urlShortener:.init(configuration:.init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true)))
        var focusedInput=collectedTree;focusedInput.focusedElement=constructedNode
        let transformedTree=try EventStreamNativeTreeTransformation.transform(focusedInput,using:[.filterActions],
            context:&transformationContext,snapshots:reader) {_,_ in preconditionFailure("action pass must not render")}
        check("native tree driver preserves external hierarchy and captured field",transformedTree.preorder.map(\.node.identifier)==collectedTree.preorder.map(\.node.identifier) && transformedTree.preorder.first {$0.node.identifier=="snapshot-field"}?.node.value=="snapshot-before")
        check("native tree driver preserves independent actual focused element",transformedTree.focusedElement.map {CFEqual($0.element.element,field)}==true)
        let applicationSource=reader.node(application),windowSource=reader.node(fixtureWindow)
        let nativeContext=EventStreamNativeTransformationContext.make(type:.eventStreamContext,application:applicationSource,window:windowSource)
        check("native context owner preserves type and URL defaults",nativeContext.type == .eventStreamContext && nativeContext.urlShortener.configuration == .init(individualLimit:nil,totalLimit:nil,includeQuery:true,includeFragment:true))
        check("ordinary AppKit fixture is not inferred to be Catalyst or Chrome",!nativeContext.isCatalyst && !nativeContext.isWebShaped && !nativeContext.isChromium)
        var nativeContextIO=EventStreamNativeTransformationContextIO.native,chromeEvents:[String]=[],observedChrome=false
        let nativeCount=nativeContextIO.arrayCount,nativeArray=nativeContextIO.arrayValues,nativeSupported=nativeContextIO.supported
        nativeContextIO.arrayCount={element,name in chromeEvents.append("count");return nativeCount(element,name)}
        nativeContextIO.arrayValues={element,name,index,maximum in
            precondition(index==0 && maximum==1);chromeEvents.append("array");return nativeArray(element,name,index,maximum)
        }
        nativeContextIO.supported={element in
            chromeEvents.append("supported");let names=nativeSupported(element);observedChrome=names.contains("ChromeAXNodeId");return names
        }
        let chromeProbe=EventStreamNativeTransformationContextBackend(io:nativeContextIO).firstChildHasChromeNodeID(windowSource)
        check("native first-child probe uses actual count array and supported attributes",chromeEvents==["count","array","supported"] && chromeProbe==observedChrome)
        let windowID=(ready["window"] as! NSNumber).uint32Value
        let windowInfo=(CGWindowListCopyWindowInfo(.optionIncludingWindow,windowID) as? [[String:Any]])?.first
        let bounds=(windowInfo?[kCGWindowBounds as String] as? [String:Any]).flatMap {CGRect(dictionaryRepresentation:$0 as CFDictionary)}
        check("native transformation window frame agrees with independent WindowServer bounds",nativeContext.windowFrame.map {actual in bounds.map {abs(actual.minX-$0.minX)<0.5 && abs(actual.minY-$0.minY)<0.5 && abs(actual.width-$0.width)<0.5 && abs(actual.height-$0.height)<0.5} ?? false}==true)
        let contextualTree=try EventStreamNativeTreeTransformation.transform(focusedInput,type:.eventStreamContext,
            application:applicationSource,window:windowSource,using:[.filterActions]) {_,_ in preconditionFailure("must not render")}
        check("context-creating native entry processes actual captured tree",contextualTree.tree.preorder.first {$0.node.identifier=="snapshot-field"}?.node.value=="snapshot-before" && contextualTree.context.windowFrame==nativeContext.windowFrame)
        var renderingContext=nativeContext
        let nativeDescription=EventStreamNativeNodeRendering.description(constructedNode,context:&renderingContext)
        check("native renderer includes external field value editing state and identifier",nativeDescription.contains("snapshot-before") && nativeDescription.contains("(settable)") && nativeDescription.contains("snapshot-field"))
        let defaultRenderedTree=try EventStreamNativeTreeTransformation.transform(focusedInput,type:.eventStreamContext,
            application:applicationSource,window:windowSource,using:[.shared(.flattenRedundantHierarchy)])
        check("native whole-tree default renderer preserves actual editable field",defaultRenderedTree.tree.preorder.contains {$0.node.identifier=="snapshot-field" && $0.node.value=="snapshot-before"})
        if let collectedField {
            var edited=collectedField.node;edited.title="presentation-only";edited.value="presentation-only"
            let target=collectedField.replacing(node:edited,children:[])
            var rebuilt:[EventStreamCollectedItem<EventStreamAXNode>]=[]
            EventStreamNativeTreeTransformation.rebuild(&rebuilt,target:target,context:transformationContext,snapshots:reader)
            check("native rebuild recaptures source rather than edited presentation",rebuilt.first?.node.value=="snapshot-before" && rebuilt.first?.node.title != "presentation-only")
            check("native rebuild resets source path and retains actual AX identity",rebuilt.first?.path==[] && rebuilt.first.map {CFEqual($0.node.element.element,field)}==true)
            EventStreamNativeTreeTransformation.rebuild(&rebuilt,target:target,context:transformationContext,snapshots:reader)
            check("native rebuild has a new visited set for each append",rebuilt.count==2 && rebuilt.allSatisfy {$0.path.isEmpty})
        }
        let hierarchyTransaction=EventStreamNativeTransactions(snapshots:reader).capture(field)
        check("actual hierarchy SPI captures external editable field",hierarchyTransaction.snapshots.attributeTable[identity]?["AXValue"] as? String == "snapshot-before")
        check("actual hierarchy builds role frequency for external field",(hierarchyTransaction.roleFrequency["AXTextField"] ?? 0)>0)
        EventStreamNativeTransactions(snapshots:reader).withSubtree(EventStreamAXNode(field)) {node in
            check("actual subtree operation supplies captured external value",node.attribute("AXValue") as? String == "snapshot-before" && EventStreamTreeTransactions.current != nil)
        }
        check("actual subtree operation clears transaction after return",EventStreamTreeTransactions.current==nil)
        EventStreamTreeTransactions.$current.withValue(hierarchyTransaction) {
            check("actual hierarchy scope supplies captured native node",reader.node(field).attribute("AXValue") as? String == "snapshot-before")
        }
        try "change".write(to:directory.appendingPathComponent("command"),atomically:true,encoding:.utf8)
        let deadline=Date().addingTimeInterval(5)
        while (try? String(contentsOf:directory.appendingPathComponent("state"),encoding:.utf8)) != "changed" {
            guard Date()<deadline else {throw NSError(domain:"NativeSnapshotFixture",code:2)}
            Thread.sleep(forTimeInterval:0.01)
        }
        check("owned fixture actually changes its editable value",raw(field,"AXValue") as? String == "snapshot-after")
        check("collected native tree retains pre-edit field snapshot",collectedField?.node.value=="snapshot-before")
        EventStreamTreeTransactions.$current.withValue(hierarchyTransaction) {
            check("actual hierarchy scope retains pre-edit value",reader.node(field).attribute("AXValue") as? String == "snapshot-before")
        }
        let refreshedHierarchy=EventStreamNativeTransactions(snapshots:reader).capture(field)
        check("fresh native hierarchy observes actual field edit",refreshedHierarchy.snapshots.attributeTable[identity]?["AXValue"] as? String == "snapshot-after")
        check("transaction fallback preserves its earlier value",reader.capture(field,transaction:transaction).attributes["AXValue"] as? String == "snapshot-before")
        check("existing snapshot node preserves earlier cached value",cachedNode.attribute("AXValue") as? String == "snapshot-before")
        check("capture without transaction observes new native value",reader.capture(field).attributes["AXValue"] as? String == "snapshot-after")
        check("native transformed value observes fresh external edit",EventStreamNativeValue.construct(reader.node(field)).value=="snapshot-after")
        let copy=transaction
        check("transaction copy shares same native fallback snapshot",reader.capture(field,transaction:copy).attributes["AXValue"] as? String == "snapshot-before")
        let seed=EventStreamNativeSnapshots.Transaction(attributeTable:[identity:["AXValue":"transaction-seed" as NSString]],requestedAttributes:["AXValue","AXRole"],fallbackCache:transaction.fallbackCache)
        let seeded=reader.node(field,transaction:seed)
        check("native transaction seed takes precedence over live and cached data",seeded.attribute("AXValue") as? String == "transaction-seed" && seeded.attribute("AXRole")==nil)
        check("native transaction node retains requested capability marker",seeded.transactionAttributes==["AXValue","AXRole"])
        check("seed does not overwrite another transaction fallback",reader.capture(field,transaction:transaction).attributes["AXValue"] as? String == "snapshot-before")
        transaction.fallbackCache.clear()
        check("clearing transaction fallback captures fresh native value",reader.capture(field,transaction:transaction).attributes["AXValue"] as? String == "snapshot-after")
        child.terminate();child.waitUntilExit()
        let terminated=reader.capture(field)
        check("terminated app yields empty native discovery without stale fallback",terminated.supportedAttributes.isEmpty && terminated.attributes.isEmpty)
        let terminatedHierarchy=EventStreamNativeTransactions(snapshots:reader).capture(field)
        check("terminated app hierarchy has no stale prefetched entries",terminatedHierarchy.partialValues.isEmpty && terminatedHierarchy.roleFrequency.isEmpty)
        print("EVENT STREAM NATIVE SNAPSHOTS: \(checks) checks passed")
        guard failures==0 else {throw NSError(domain:"NativeSnapshotFixture",code:failures)}
    }
}
