import AppKit
import ApplicationServices

private final class FocusTableFixturePanel:NSPanel {
    override var canBecomeKey:Bool {false}
    override var canBecomeMain:Bool {false}
}

@MainActor final class FocusTableData:NSObject,NSTableViewDataSource,NSTableViewDelegate {
    func numberOfRows(in tableView:NSTableView)->Int {3}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        let text=NSTextField(labelWithString:"focus row \(row)");text.setAccessibilityIdentifier("focus-cell-\(row)");return text
    }
}

@MainActor final class CaptureContextImageView:NSImageView {
    // NSImageView adds visual padding to its default accessibility frame.
    // This disposable fixture exposes the visible view bounds explicitly.
    override func accessibilityFrame()->NSRect {NSAccessibility.screenRect(fromView:self,rect:bounds)}
}

@main enum EventStreamTreeFocusNativeTests {
    @MainActor static var checks=0
    @MainActor static func check(_ label:String,_ result:@autoclosure()->Bool) {
        guard result() else {fatalError("FAIL: \(label)")};checks += 1;print("PASS: \(label)")
    }
    @MainActor static func fixture() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        let window=FocusTableFixturePanel(contentRect:.init(x:90,y:90,width:760,height:240),styleMask:[.titled,.nonactivatingPanel],backing:.buffered,defer:false)
        window.hidesOnDeactivate=false
        window.title="Disposable EventStream Focus Table";window.isReleasedWhenClosed=false
        let scroll=NSScrollView(frame:.init(x:15,y:15,width:430,height:210)),table=NSTableView(),data=FocusTableData()
        let column=NSTableColumn(identifier:.init("name"));column.width=400;table.addTableColumn(column)
        table.headerView=nil;table.rowHeight=35;table.allowsMultipleSelection=true
        table.setAccessibilityIdentifier("focus-selection-table");table.dataSource=data;table.delegate=data
        scroll.documentView=table;window.contentView!.addSubview(scroll);table.reloadData()
        let largeImage=CaptureContextImageView(frame:.init(x:470,y:40,width:130,height:130))
        largeImage.image=NSImage(size:largeImage.frame.size,flipped:false) {rect in
            NSColor.systemBlue.setFill();rect.fill();return true
        }
        largeImage.setAccessibilityIdentifier("capture-large-image");window.contentView!.addSubview(largeImage)
        let boundaryImage=CaptureContextImageView(frame:.init(x:620,y:40,width:100,height:130))
        boundaryImage.image=NSImage(size:boundaryImage.frame.size,flipped:false) {rect in
            NSColor.systemGreen.setFill();rect.fill();return true
        }
        boundaryImage.setAccessibilityIdentifier("capture-boundary-image");window.contentView!.addSubview(boundaryImage)
        table.selectRowIndexes(IndexSet([0,2]),byExtendingSelection:false)
        window.orderBack(nil);window.makeFirstResponder(table);app.finishLaunching()
        FileHandle.standardInput.readabilityHandler={handle in
            let bytes=handle.availableData
            guard !bytes.isEmpty else {handle.readabilityHandler=nil;return}
            if String(decoding:bytes,as:UTF8.self).contains("rename") {
                DispatchQueue.main.async {
                    guard let cell=table.view(atColumn:0,row:0,makeIfNecessary:false) as? NSTextField else {exit(3)}
                    cell.stringValue="focus row 0 changed"
                    FileHandle.standardOutput.write(Data("renamed\n".utf8))
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+0.4) {
            FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject:["pid":getpid(),"window":window.windowNumber,"isKeyWindow":window.isKeyWindow,"tableIsFirstResponder":window.firstResponder === table])+Data([10]))
        }
        DispatchQueue.main.asyncAfter(deadline:.now()+90) {app.terminate(nil)}
        withExtendedLifetime((data,table,window,largeImage,boundaryImage)) {app.run()}
    }
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.contains("--fixture") {fixture();return}
        let accessibilityTrusted=AXIsProcessTrusted()
        let sessionLocked=(CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        guard accessibilityTrusted,!sessionLocked else {
            fputs("Native focus tests require unlocked macOS and Accessibility: accessibility=\(accessibilityTrusted), locked=\(sessionLocked).\n",stderr);exit(2)
        }
        let child=Process(),pipe=Pipe(),control=Pipe();child.executableURL = .init(fileURLWithPath:CommandLine.arguments[0]);child.arguments=["--fixture"]
        child.standardOutput=pipe;child.standardInput=control;child.standardError=FileHandle.standardError;try child.run()
        let watchdog=DispatchWorkItem {if child.isRunning {child.terminate()}}
        DispatchQueue.global().asyncAfter(deadline:.now()+60,execute:watchdog)
        defer {watchdog.cancel();if child.isRunning {child.terminate()};child.waitUntilExit()}
        let ready=try JSONSerialization.jsonObject(with:pipe.fileHandleForReading.availableData) as! [String:Any]
        check("native table fixture retains logical focus without receiving keyboard focus",ready["isKeyWindow"] as? Bool == false && ready["tableIsFirstResponder"] as? Bool == true)
        let app=AXUIElementCreateApplication((ready["pid"] as! NSNumber).int32Value)
        func raw(_ element:AXUIElement,_ name:String)->AnyObject? {
            var value:CFTypeRef?;return AXUIElementCopyAttributeValue(element,name as CFString,&value) == .success ? value:nil
        }
        func refs(_ raw:AnyObject?)->[AXUIElement] {
            (raw as? [AnyObject] ?? []).compactMap {CFGetTypeID($0)==AXUIElementGetTypeID() ? unsafeBitCast($0,to:AXUIElement.self):nil}
        }
        var queue=refs(raw(app,"AXWindows")),index=0,table:AXUIElement?
        while index<queue.count && index<150 {
            let next=queue[index];index += 1
            if raw(next,"AXIdentifier") as? String == "focus-selection-table" {table=next;break}
            queue.append(contentsOf:refs(raw(next,"AXChildren")))
        }
        guard let table else {throw NSError(domain:"NativeFocusTableMissing",code:1)}
        let expected=refs(raw(table,"AXSelectedRows")),reader=EventStreamNativeSnapshots(),source=reader.node(table)
        check("real table exposes two selected native rows",expected.count==2 && raw(table,"AXRole") as? String == "AXTable")
        let selection=EventStreamNativeSelection().elements(of:source)
        check("native selection getter agrees with independent raw AX selection",selection.map {$0.count==expected.count && zip($0,expected).allSatisfy {CFEqual($0.element,$1)}}==true)
        let node=EventStreamNativeNode.construct(source,context:.init(kind:1))
        let context=EventStreamNativeTransformationContext.make(type:.eventStreamContext,application:reader.node(app),window:nil)
        var full=EventStreamTreeCollection(backend:EventStreamNativeTreeCollectionBackend(snapshots:reader)).collect(source,context:.init(kind:1))
        full.focusedElement=node
        check("collected real table contains every selected native identity",expected.allSatisfy {expected in full.preorder.contains {CFEqual($0.node.element.element,expected)}})
        let focused=EventStreamNativeTreeFocus.make(&full,context:context)!
        check("native focus tree wraps actual table and ordered selected rows",focused.roots.count==1 && focused.roots[0].node.role=="AXTable" && focused.roots[0].children.count==2 && zip(focused.roots[0].children,expected).allSatisfy {CFEqual($0.node.element.element,$1)})
        check("all-found native selections discard row descendants and subsets",focused.roots[0].children.allSatisfy {$0.children.isEmpty && $0.childrenSubset==nil})
        check("native focus output retains independent actual focus",focused.focusedElement.map {CFEqual($0.element.element,table)}==true && focused.roots[0].subtree.focusedElement==nil)
        var missing=EventStreamCollectedTree<EventStreamAXNode>(roots:[],focusedElement:node)
        let recovered=EventStreamNativeTreeFocus.make(&missing,context:context,snapshots:reader)!
        check("missing native selections recapture both actual rows",recovered.roots[0].children.count==2 && zip(recovered.roots[0].children,expected).allSatisfy {CFEqual($0.node.element.element,$1)})
        check("native recapture starts each selected source at empty path",recovered.roots[0].children.allSatisfy {$0.path.isEmpty})
        check("native recapture preserves actual selected row descendants",recovered.roots[0].children.allSatisfy {!$0.children.isEmpty})
        check("original real hierarchy remains available after focus extraction",full.preorder.count>focused.preorder.count && full.hasCachedTable)
        var renderContext=context
        let rendered=EventStreamNativeRenderForest.build(full,context:&renderContext)
        check("native render forest retains every selected row identity",expected.allSatisfy {selected in rendered.preorder.contains {CFEqual($0.identity.element,selected)}} && rendered.preorder.allSatisfy {$0.elementID==nil})
        func sourceReference(at path:[Int])->AXUIElement? {
            guard let first=path.first,full.roots.indices.contains(first) else {return nil}
            var current=full.roots[first]
            for index in path.dropFirst() {guard current.children.indices.contains(index) else {return nil};current=current.children[index]}
            return current.node.element.element
        }
        check("native render paths resolve to independently captured source identities",!rendered.roots.isEmpty && rendered.preorder.allSatisfy {node in node.sourcePath.flatMap {sourceReference(at:$0)}.map {CFEqual($0,node.identity.element)}==true})
        let renderedFocus=EventStreamNativeRenderForest.build(focused,context:&renderContext)
        check("native focused forest binds source focus and serializes selected rows",renderedFocus.isFocusTree && renderedFocus.roots.count==1 && renderedFocus.lines().count>=3)
        EventStreamRenderIDs.setInitialIDs(rendered)
        let numericIDs=try EventStreamRenderIDs.assign(main:rendered,focus:renderedFocus)
        check("native main IDs follow render preorder and focus identities reuse them",rendered.preorder.enumerated().allSatisfy {$0.element.elementID==$0.offset} && renderedFocus.preorder.allSatisfy {$0.elementID==numericIDs.values[$0.identity]})
        check("native selected numeric IDs recover actual focus source rows",expected.allSatisfy {selected in
            let key=EventStreamSnapshotAXIdentity(element:selected)
            guard let id=numericIDs.values[key],let item=EventStreamRenderIDs.item(for:id,in:numericIDs,tree:full,focus:focused,identity:{EventStreamSnapshotAXIdentity(element:$0.element)}) else {return false}
            return CFEqual(item.node.element.element,selected)
        })
        let fresh=EventStreamNativeRenderForest.build(full,context:&renderContext)
        for next in fresh.preorder {
            if let old=rendered.preorder.first(where:{$0.identity==next.identity}) {EventStreamRenderIDs.inherit(from:old,to:next)}
        }
        let inherited=try EventStreamRenderIDs.assign(main:fresh)
        check("native paired inheritance retains numeric identity mapping on recapture",inherited.values==numericIDs.values)
        let nativeRevision=try EventStreamNativeTreeRevision.root(full,focusTree:focused,context:&renderContext,
            now:{Date(timeIntervalSince1970:1234567890.125)},randomBytes:{Array(repeating:0xab,count:16)})
        let beforeMutationSnapshot=try nativeRevision.renderTreeSnapshot()
        let beforeFocusSnapshot=try nativeRevision.focusRenderTreeSnapshot()
        check("native revision root creates lowercase timestamp lineage",nativeRevision.lineageID=="011f71fb-04cd-7bab-abab-abababababab")
        check("native revision owns main focus and shared numeric map",nativeRevision.previousRevision==nil && nativeRevision.changes.isEmpty && nativeRevision.ids.values==numericIDs.values && nativeRevision.focusRenderTree != nil)
        check("native revision numeric lookup resolves independent selected rows",expected.allSatisfy {selected in
            guard let id=nativeRevision.ids.values[.init(element:selected)],let element=nativeRevision.element(for:id) else {return false}
            return CFEqual(element.element,selected)
        })
        check("native revision snapshots retain subject and focus",beforeMutationSnapshot.subjectID==nativeRevision.lineageID && beforeFocusSnapshot?.isFocus==true)
        // Mutate an existing view in the other process, then capture it with a
        // new snapshot owner. Pairing below is supplied by the production diff
        // algorithm, rather than a fixture-side lookup by identity.
        control.fileHandleForWriting.write(Data("rename\n".utf8))
        check("external fixture acknowledged real visible text mutation",String(decoding:pipe.fileHandleForReading.availableData,as:UTF8.self).contains("renamed"))
        let changedReader=EventStreamNativeSnapshots()
        var changedSource=EventStreamTreeCollection(backend:EventStreamNativeTreeCollectionBackend(snapshots:changedReader)).collect(changedReader.node(table),context:.init(kind:1))
        changedSource.focusedElement=EventStreamNativeNode.construct(changedReader.node(table),context:.init(kind:1))
        let changed=EventStreamNativeRenderForest.build(changedSource,context:&renderContext)
        check("fresh native render capture observes changed text",changed.preorder.contains {$0.text.contains("focus row 0 changed")} && !rendered.preorder.contains {$0.text.contains("focus row 0 changed")})
        var differences=EventStreamRenderDifference(oldTree:rendered,newTree:changed).buffer()
        check("production diff pairs real native text changes as updates",differences.changes.contains {$0.kind == .update && $0.new?.node.text.contains("focus row 0 changed")==true && $0.old?.node.identity==$0.new?.node.identity})
        for difference in differences.changes {difference.inheritElementID()}
        let changedIDs=try EventStreamRenderIDs.assign(main:changed)
        check("production diff preserves native numeric IDs through actual text mutation",changedIDs.values==inherited.values)
        differences.sortChangesDepthFirst()
        check("native diff output reports real visible text change",differences.changes.flatMap {$0.lines()}.contains {$0.hasPrefix("~") && $0.contains("focus row 0 changed")})
        let appendedRevision=try EventStreamNativeTreeRevision.appending(nativeRevision,tree:changedSource,context:&renderContext)
        check("native revision append owns lineage and predecessor",appendedRevision.previousRevision===nativeRevision && appendedRevision.lineageRootRevision===nativeRevision && appendedRevision.lineageID==nativeRevision.lineageID)
        check("native revision append integrates automatic update and ID continuity",appendedRevision.ids.values==nativeRevision.ids.values && appendedRevision.changes.contains {$0.kind == .update && $0.new?.node.text.contains("focus row 0 changed")==true})
        check("native append without focus omits previous focus tree",appendedRevision.focusTree==nil && appendedRevision.focusRenderTree==nil)
        let afterMutationSnapshot=try appendedRevision.renderTreeSnapshot()
        check("native revision snapshots preserve prior text across real mutation",afterMutationSnapshot.renders.contains {$0.text.contains("focus row 0 changed")} && !beforeMutationSnapshot.renders.contains {$0.text.contains("focus row 0 changed")})
        var budgetNotices:[EventStreamDifferenceLineBudgetExceeded]=[]
        let revisionLines=appendedRevision.differenceLines(from:nativeRevision,options:[],summarizesRemovedElementIDs:true,
            ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{budgetNotices.append($0)})
        check("native revision bounded difference emits actual visible text update",revisionLines?.contains {$0.hasPrefix("~") && $0.contains("focus row 0 changed")}==true && budgetNotices.isEmpty)
        let inspector=appendedRevision.renderTreeInspectorPayload()!
        check("native inspector retains current previous and first value snapshots",inspector.current==afterMutationSnapshot && inspector.previous==beforeMutationSnapshot && inspector.first==beforeMutationSnapshot)
        check("native self difference is available and empty",appendedRevision.differenceLines(from:appendedRevision,options:[],summarizesRemovedElementIDs:true,
            ignoreDifferenceLineBudget:false,onLineBudgetExceeded:{budgetNotices.append($0)})==[] && budgetNotices.isEmpty)
        let inspectorRoundtrip=try JSONDecoder().decode(EventStreamRenderInspectorPayload.self,from:JSONEncoder().encode(inspector))
        check("native inspector coding preserves all captured snapshot fields",inspectorRoundtrip==inspector)
        var imageQueue=refs(raw(app,"AXWindows")),imageIndex=0,large:AXUIElement?,boundary:AXUIElement?
        while imageIndex<imageQueue.count && imageIndex<200 {
            let next=imageQueue[imageIndex];imageIndex += 1
            let identifier=raw(next,"AXIdentifier") as? String
            if identifier=="capture-large-image" {large=next}
            if identifier=="capture-boundary-image" {boundary=next}
            imageQueue.append(contentsOf:refs(raw(next,"AXChildren")))
        }
        guard let large,let boundary else {throw NSError(domain:"NativeCaptureImagesMissing",code:1)}
        let largeNode=EventStreamNativeNode.construct(reader.node(large),context:.init(kind:1))
        let boundaryNode=EventStreamNativeNode.construct(reader.node(boundary),context:.init(kind:1))
        check("external fixture exposes actual native image roles",largeNode.role=="AXImage" && boundaryNode.role=="AXImage")
        func imageTree(_ image:EventStreamTransformedNode<EventStreamAXNode>)->EventStreamCollectedTree<EventStreamAXNode> {
            // Nine captured table nodes keep this policy fixture above the
            // small-tree threshold; image role and fresh AXSize remain real.
            .init(roots:([image]+Array(repeating:node,count:9)).map {.init(node:$0,path:[],children:[],childrenSubset:nil)})
        }
        let imageIO=EventStreamScreenshotContextIO.native
        print("Native image dimensions: large=\(String(describing:imageIO.uncachedSize(reader.node(large)))) boundary=\(String(describing:imageIO.uncachedSize(reader.node(boundary)))) bundle=\(String(describing:imageIO.bundleIdentifier(reader.node(app))))")
        check("native screenshot policy reads actual uncached image dimensions",imageIO.uncachedSize(reader.node(large))==CGSize(width:130,height:130) && EventStreamNativeScreenshotContextPolicy.needed(imageTree(largeNode),application:reader.node(app)))
        check("native screenshot policy preserves exactly100 width boundary",imageIO.uncachedSize(reader.node(boundary))==CGSize(width:100,height:130) && !EventStreamNativeScreenshotContextPolicy.needed(imageTree(boundaryNode),application:reader.node(app)))
        check("native always-include override applies before app exemption",EventStreamNativeScreenshotContextPolicy.needed(imageTree(boundaryNode),application:reader.node(app),alwaysIncludeScreenshot:true,
            io:.init(bundleIdentifier:{_ in "com.example.agent"},uncachedSize:{_ in fatalError("override must skip size")},actionDescriptions:{_ in fatalError("override must skip actions")})))
        let contextOwner=EventStreamNativeContext();var captureCalls=0,receivedPredecessor=false
        let connected=contextOwner.makeAXCapture(captureTree:{context,previous in
            receivedPredecessor=receivedPredecessor || previous===nativeRevision
            let revision=captureCalls==0 ? nativeRevision:appendedRevision;captureCalls += 1
            return .init(revision:revision,windowID:context.nativeWindow.id,
                app:.init(name:"Native capture fixture",secureInput:false,processIdentifier:context.nativeWindow.processIdentifier,bundleIdentifier:nil),
                window:.init(title:context.nativeWindow.title,url:nil,windowID:context.nativeWindow.id))
        })
        let target=EventStreamEventTarget(identity:.init(processIdentifier:(ready["pid"] as! NSNumber).int32Value,windowID:(ready["window"] as! NSNumber).uint32Value),app:nil,window:nil)
        let connectedFull=try await connected.capture(target,preferDiff:false)
        let connectedDiff=try await connected.capture(target,preferDiff:true)
        check("native context capture binds full selection serialization",connectedFull.ax?.mode == .fullTree && connectedFull.ax?.text==nativeRevision.eventStreamDescription(.fullTree,lineOptions:[.withoutRemovalSubtree],ignoreDifferenceLineBudget:true))
        check("native context capture binds previous revision serialization",connectedDiff.ax?.mode == .diffFromPrevious && connectedDiff.ax?.text.contains("focus row 0 changed")==true && receivedPredecessor && captureCalls==2)
        let phaseReader=EventStreamNativeSnapshots()
        var phaseSource=EventStreamTreeCollection(backend:EventStreamNativeTreeCollectionBackend(snapshots:phaseReader)).collect(phaseReader.node(table),context:.init(kind:1))
        phaseSource.focusedElement=EventStreamNativeNode.construct(phaseReader.node(table),context:.init(kind:1))
        var phaseContext=EventStreamNativeTransformationContext.make(type:.eventStreamContext,application:phaseReader.node(app),window:nil)
        let rawPhaseFocus=EventStreamNativeTreeFocus.make(&phaseSource,context:phaseContext,snapshots:phaseReader)
        let transformedPair=try EventStreamNativeCaptureTransformation.run(main:phaseSource,focus:rawPhaseFocus,context:&phaseContext,snapshots:phaseReader)
        let phaseRoot=try EventStreamNativeCaptureTransformation.revision(transformedPair,previous:nil,enableAXDiffing:true,context:&phaseContext)
        check("native capture phases retain actual changed table text",phaseRoot.renderTree.lines().contains {$0.contains("focus row 0 changed")})
        check("native capture phases preserve independently selected focus",transformedPair.focus != nil && phaseRoot.focusTree != nil && phaseRoot.focusRenderTree != nil)
        let phaseNext=try EventStreamNativeCaptureTransformation.revision(transformedPair,previous:phaseRoot,enableAXDiffing:true,context:&phaseContext)
        check("native capture phase revision append preserves actual IDs and empty difference",phaseNext.previousRevision===phaseRoot && phaseNext.ids.values==phaseRoot.ids.values && phaseNext.eventStreamDescription(.difference(from:.previous),lineOptions:[],ignoreDifferenceLineBudget:false)=="no_change")
        let phaseFresh=try EventStreamNativeCaptureTransformation.revision(transformedPair,previous:phaseRoot,enableAXDiffing:false,context:&phaseContext)
        check("native capture phases honor disabled diffing with actual source",phaseFresh.previousRevision==nil && phaseFresh.lineageID != phaseRoot.lineageID)
        let actualWindow=refs(raw(app,"AXWindows")).first!
        var coreContext=EventStreamNativeTransformationContext.make(type:.eventStreamContext,application:phaseReader.node(app),window:phaseReader.node(actualWindow))
        let core=try EventStreamNativeCaptureCore.capture(root:phaseReader.node(table),window:phaseReader.node(actualWindow),application:phaseReader.node(app),
            focusedElement:phaseReader.node(table),cachedTree:phaseSource,context:&coreContext,alwaysIncludeScreenshot:true,
            backend:.init(snapshots:phaseReader))
        check("native common core joins cached source focus policy transformation and revision",core.revision.renderTree.lines().contains {$0.contains("focus row 0 changed")} && core.revision.focusTree != nil && core.screenshotNeededForContext)
        check("native common core preserves default context and metadata",core.contextType == .eventStreamContext && core.webAreaURL==nil && !core.copyMenuItemIsEnabled)
        let coreNext=try EventStreamNativeCaptureCore.capture(root:phaseReader.node(table),window:phaseReader.node(actualWindow),application:phaseReader.node(app),
            focusedElement:phaseReader.node(table),cachedTree:phaseSource,previous:core.revision,context:&coreContext,alwaysIncludeScreenshot:true,
            backend:.init(snapshots:phaseReader))
        check("native common core continuation forwards predecessor and stable output",coreNext.revision.previousRevision===core.revision && coreNext.revision.eventStreamDescription(.difference(from:.previous),lineOptions:[],ignoreDifferenceLineBudget:false)=="no_change")
        let coreWindow=try EventStreamNativeCaptureCore.capture(root:phaseReader.node(actualWindow),window:phaseReader.node(actualWindow),application:phaseReader.node(app),
            focusedElement:phaseReader.node(table),context:&coreContext,backend:.init(snapshots:phaseReader))
        check("native common core collects actual window and discovers screenshot context",coreWindow.revision.tree.roots.first.map {CFEqual($0.node.element.element,actualWindow)}==true && coreWindow.screenshotNeededForContext && coreWindow.revision.renderTree.lines().contains {$0.contains("focus row 0 changed")})
        let resolvedParent=try contextOwner.resolver.captureContext(target)
        let parentInput=EventStreamCaptureContext(application:resolvedParent.application,window:resolvedParent.window,
            focusedElement:Optional<EventStreamAXNode>.none,nativeWindow:resolvedParent.nativeWindow)
        var observedParentTransaction:AXUIElement?
        let parentIO=EventStreamNativeCaptureSourceIO.native
        let observedSource=EventStreamNativeRawCaptureBackend(snapshots:phaseReader,io:.init(attribute:parentIO.attribute,bundleInfo:{element in
            observedParentTransaction=EventStreamTreeTransactions.current?.root
            return parentIO.bundleInfo(element)
        },isMarkerRange:parentIO.isMarkerRange))
        let parentBackend=EventStreamNativeSelectionExtractorBackend<NSObject>(enableAccessibility:{_,_,_ in
            fatalError("Explicitly disabled native enablement must not acquire")
        },disable:{_ in fatalError("No native assertion was acquired")},snapshots:phaseReader,source:observedSource)
        let parentSelection=try EventStreamNativeSelectionExtractor.extract(from:parentInput,type:.eventStreamContext,
            performAccessibilityEnablement:false,backend:parentBackend)
        check("native parent captures real source and preserves AX CG window ownership",parentSelection.applicationWindow.nativeWindow==parentInput.nativeWindow && CFEqual(parentSelection.applicationWindow.window.element,parentInput.window.element) && parentSelection.invalidationMonitor==nil && parentSelection.windowRevision.renderTree.lines().contains {$0.contains("focus row 0 changed")})
        check("native parent installs actual root transaction and restores TaskLocal",observedParentTransaction.map {CFEqual($0,parentInput.window.element)}==true && EventStreamTreeTransactions.current==nil)
        let parentNext=try EventStreamNativeSelectionExtractor.extract(from:parentInput,type:.eventStreamContext,
            previous:parentSelection.windowRevision,performAccessibilityEnablement:false,backend:parentBackend)
        check("native parent forwards revision continuation and output context",parentNext.windowRevision.previousRevision===parentSelection.windowRevision && parentNext.contextType == .eventStreamContext)
        let parentMonitor=EventStreamTreeInvalidationMonitor(application:app)
        let parentTransaction=EventStreamNativeTransactions(snapshots:phaseReader).capture(table)
        let parentCache=EventStreamNativeCaptureTreeCache(tree:phaseSource,transaction:parentTransaction,invalidationMonitor:parentMonitor)
        let parentCached=try EventStreamNativeSelectionExtractor.extract(from:parentInput,type:.fullUIContext,cache:parentCache,
            rootOverride:phaseReader.node(table),performAccessibilityEnablement:false,alwaysIncludeScreenshot:true,backend:parentBackend)
        check("native parent reuses cached raw tree transaction and full-context monitor",parentCached.invalidationMonitor===parentMonitor && parentCached.screenshotNeededForContext && parentCached.windowRevision.renderTree.lines().contains {$0.contains("focus row 0 changed")} && observedParentTransaction.map {CFEqual($0,table)}==true && EventStreamTreeTransactions.current==nil)
        let observedFactoryReader=EventStreamNativeSnapshots()
        var factoryHierarchyCopies=0
        let factoryHierarchy=EventStreamHierarchyCapture(keys:.init(skipInspection:"skip",arrayAttributes:"arrays",truncateStrings:"truncate",maximumArrayCount:"maximum",value:"value",count:"count",incomplete:"incomplete"),copy:{_,_,_,_ in
            factoryHierarchyCopies += 1;return nil
        })
        let factoryTransactions=EventStreamNativeTransactions(snapshots:observedFactoryReader,hierarchy:factoryHierarchy)
        contextOwner.resolver.recordCapturedURL(URL(string:"https://obsolete.example"),for:parentInput.nativeWindow.id)
        let nativeFactory=contextOwner.makeNativeAXCapture(prefetchConfiguration:{["ax_prefetch_enabled":false]},snapshots:observedFactoryReader,transactions:factoryTransactions)
        let factoryFull=try await nativeFactory.capture(target,preferDiff:false)
        check("actual native factory captures full tree without injected capture owner",factoryFull.ax?.mode == .fullTree && factoryFull.ax?.text.contains("focus row 0 changed")==true)
        check("actual native factory preserves selected app window and cached AX title",factoryFull.app?.processIdentifier==parentInput.nativeWindow.processIdentifier && factoryFull.window?.windowID==parentInput.nativeWindow.id && factoryFull.window?.title=="Disposable EventStream Focus Table")
        let factoryDiff=try await nativeFactory.capture(target,preferDiff:true)
        check("actual native factory continues same-window revision",factoryDiff.ax?.mode == .diffFromPrevious && factoryDiff.window?.windowID==factoryFull.window?.windowID)
        check("actual native factory scopes configured prefetch and removes obsolete URL",factoryHierarchyCopies==0 && EventStreamTreeTransactions.prefetchEnabled && contextOwner.resolver.windowURLs[parentInput.nativeWindow.id]==nil && factoryFull.window?.url==nil)
        print("EVENT STREAM NATIVE TREE FOCUS: \(checks) checks passed")
    }
}
