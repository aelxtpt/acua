import AppKit
import SwiftUI
import ObjectiveC

private final class NativeProbeCounter: @unchecked Sendable {
    private let lock=NSLock()
    private var storage=0
    func increment() { lock.withLock { storage += 1 } }
    var value:Int { lock.withLock { storage } }
}
@MainActor private final class ProbeDragSession: SettingsAccessoryDraggingSession {
    var animatesToStartingPositionsOnCancelOrFail=false
}
@MainActor private final class ProbeDropDelegate: SettingsAccessoryDragDelegate {
    weak var source:SettingsAccessoryDraggableView?
    var drops=[CGPoint](),hiddenDuringDrop=[Bool]()
    func settingsAccessoryDidDrop(at point:CGPoint) { drops.append(point);hiddenDuringDrop.append(source?.appRowView.isHidden ?? false) }
}
@MainActor private final class NoBitmapView:NSView {
    override func bitmapImageRepForCachingDisplay(in rect:NSRect)->NSBitmapImageRep? { nil }
}

@MainActor enum OwnedSettingsAccessoryNativeChecks {
    static func run() throws {
        let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        var rows=[[String:Any]](),observations=[String:Any]()
        func check(_ ok:Bool,_ label:String) {
            rows.append(["name":label,"passed":ok])
            print("\(ok ? "PASS" : "FAIL") \(label)");fflush(stdout)
            if !ok {
                let partial:[String:Any] = ["passed":false,"results":rows,"observations":observations]
                try? JSONSerialization.data(withJSONObject:partial,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("result.json"))
            }
        }
        let fixture=output.appendingPathComponent("Owned C77.app",isDirectory:true)
        try FileManager.default.createDirectory(at:fixture.appendingPathComponent("Contents"),withIntermediateDirectories:true)
        try PropertyListSerialization.data(fromPropertyList:["CFBundleIdentifier":"test.acua.owned-c77","CFBundleName":"Owned C77"],format:.xml,options:0).write(to:fixture.appendingPathComponent("Contents/Info.plist"))
        let baseline=NSPanel(contentRect:.zero,styleMask:SettingsAccessoryWindowConfiguration.styleMask,backing:.buffered,defer:false)
        let defaultHides=baseline.hidesOnDeactivate,defaultReleased=baseline.isReleasedWhenClosed
        baseline.level = .init(rawValue:3)
        let baselineArrow=NSPanel(contentRect:CGRect(x:0,y:0,width:100,height:100),styleMask:.borderless,backing:.buffered,defer:false)
        baselineArrow.collectionBehavior = .managed
        baselineArrow.level = .init(rawValue:3)
        let beforeAttachCollection=baselineArrow.collectionBehavior.rawValue
        baseline.addChildWindow(baselineArrow,ordered:.above)
        let attachedCollection=baselineArrow.collectionBehavior.rawValue
        observations["systemChildCollection"]=["before":beforeAttachCollection,"after":attachedCollection]
        baseline.removeChildWindow(baselineArrow);baselineArrow.close()
        baseline.close()
        var callbacks=0
        let panel=AppshotPermissionAccessory(permission:.accessibility,appURL:fixture,onBack:{callbacks += 1},onDrop:{ _ in callbacks += 1})
        defer { panel.close() }
        check(panel.styleMask.rawValue==32913,"actual production accessory uses the titled utility/nonactivating/full-size mask")
        check(panel.hasShadow && panel.level.rawValue==3 && !panel.isOpaque,"actual production accessory has its shadow, level and opacity")
        check(!panel.isMovable && !panel.isMovableByWindowBackground && panel.titleVisibility == .hidden && panel.titlebarAppearsTransparent && panel.toolbarStyle.rawValue==3,"actual production titlebar and movement match the accessory setters")
        check(panel.collectionBehavior.rawValue==586,"actual production accessory uses its collection behavior")
        check(panel.hidesOnDeactivate==defaultHides && panel.isReleasedWhenClosed==defaultReleased,"unset window lifetime/deactivation properties retain native defaults")
        let background=panel.backgroundColor!.usingColorSpace(.deviceRGB)!
        check(abs(background.alphaComponent-0.001)<1e-9 && background.redComponent==1,"actual production background is white at 0.001 alpha")
        check(!panel.canBecomeKey && !panel.canBecomeMain && !panel.isVisible,"actual production accessory is hidden and cannot acquire key/main focus")
        let root=panel.contentViewController!.view
        let hosting=root.subviews.first!
        check(root !== hosting && hosting.translatesAutoresizingMaskIntoConstraints==false && root.constraints.count>=4,"actual controller keeps separate root and edge-constrained hosting view")
        let fitting=hosting.fittingSize
        check(fitting==CGSize(width:531,height:110),"actual live native column keeps the foreground fitting size")
        let contentFrame=SettingsAccessoryLayout.contentFrame(windowQuartz:CGRect(x:200,y:100,width:700,height:650),primaryScreenHeight:1200,fittingSize:fitting,audioHeading:nil)
        let frame=panel.frameRect(forContentRect:contentFrame).integral
        panel.setFrame(frame,display:false);root.layoutSubtreeIfNeeded();hosting.layoutSubtreeIfNeeded()
        check(panel.frame==frame && panel.contentView!.bounds.size==fitting,"content layout is converted to the actual utility window frame")
        check(hosting.safeAreaInsets.top==0 && hosting.safeAreaInsets.bottom==0 && hosting.safeAreaInsets.left==0 && hosting.safeAreaInsets.right==0 && hosting.safeAreaRect==hosting.frame,"actual production host suppresses safe insets and returns raw frame")
        check(hosting.layoutGuides.contains { $0.owningView === hosting && $0.frame==hosting.bounds },"actual production host keeps an additional guide spanning its full bounds")
        let children=panel.childWindows ?? []
        check(children.count==1,"actual production constructor attaches its own arrow after initialization")
        let arrow=children[0]
        observations["attachedArrow"]=["class":NSStringFromClass(type(of:arrow)),"style":arrow.styleMask.rawValue,"level":arrow.level.rawValue,"collection":arrow.collectionBehavior.rawValue,"shadow":arrow.hasShadow,"opaque":arrow.isOpaque]
        check(beforeAttachCollection==4 && arrow is NSPanel && arrow.styleMask.rawValue==0 && arrow.level.rawValue==3 && arrow.collectionBehavior.rawValue==attachedCollection && !arrow.hasShadow && !arrow.isOpaque,"actual production arrow keeps its borderless panel configuration with AppKit child behavior")
        let arrowRoot=arrow.contentViewController!.view
        check(arrowRoot !== arrowRoot.subviews.first && arrowRoot.constraints.count>=4 && arrowRoot.subviews.first?.translatesAutoresizingMaskIntoConstraints==false,"actual arrow keeps a separate controller root and edge-constrained hosting view")
        check(arrow.frame==SettingsAccessoryLayout.arrowFrame(accessory:panel.frame),"actual production frame update positions the child arrow")
        panel.setFrameOrigin(CGPoint(x:-321.25,y:45.5))
        check(arrow.frame==SettingsAccessoryLayout.arrowFrame(accessory:panel.frame),"actual production origin update also positions the child arrow")
        let capture=panel.transitionSnapshot()!
        check(capture.cornerRadius==14 && capture.image?.size==fitting && capture.frame==panel.convertToScreen(panel.contentView!.bounds).integral,"actual production constructor supplies the foreground renderer and radius14 capture")
        check(callbacks==0 && !panel.isVisible && !arrow.isVisible && !panel.isKeyWindow,"constructing and capturing the actual production owner invokes no action or visible window")
        let wrapped=panel.presentationWindow()
        check(wrapped.fittingSize()==fitting && wrapped.frameForContent(contentFrame)==panel.frameRect(forContentRect:contentFrame),"live presentation adapter reads the actual host fitting size and native content conversion")
        let shifted=panel.frame.offsetBy(dx:6,dy:5)
        wrapped.setFrame(shifted);wrapped.layout()
        check(panel.frame==shifted && arrow.frame==SettingsAccessoryLayout.arrowFrame(accessory:shifted),"live presentation adapter moves and lays out the actual panel and child arrow")
        check(wrapped.capture()?.cornerRadius==14 && wrapped.capture()?.artwork?.size==fitting,"live presentation adapter uses the actual foreground capture")
        wrapped.setAlphas(0.4)
        check(panel.alphaValue==0.4 && root.alphaValue==0.4 && arrow.alphaValue==0.4,"live presentation adapter applies alpha to panel, controller root and arrow")
        wrapped.revealAfterForward()
        check(panel.alphaValue==1 && root.alphaValue==1 && arrow.alphaValue==1 && !panel.isVisible,"forward reveal restores all three alphas without ordering the window")
        check(wrapped.forwardCompletionTarget() != nil,"actual live panel supplies a weak native forward-completion target")
        var forwarded=[CGPoint]()
        let delegatePanel=AppshotPermissionAccessory(permission:.accessibility,appURL:fixture,onBack:{},onDrop:{ forwarded.append($0) })
        let outside=CGPoint(x:-9000,y:9000)
        delegatePanel.settingsAccessoryDidDrop(at:outside)
        check(forwarded==[outside] && !delegatePanel.isVisible,"native delegate forwards raw screen coordinates to the presenter without a fresh window lookup")
        delegatePanel.close()
        let suppressed=SettingsAccessoryHostingView(rootView:Text("owned safe-area fixture"))
        suppressed.frame=CGRect(x:8,y:12,width:200,height:100);suppressed.layoutSubtreeIfNeeded()
        check(suppressed.safeAreaRect==CGRect(x:8,y:12,width:200,height:100) && suppressed.fullContentLayoutGuide.frame==suppressed.bounds,"safe rect preserves nonzero frame origin while its additional guide remains local")
        var count:UInt32=0
        let methods=class_copyMethodList(type(of:suppressed),&count)!
        let selectors=(0..<Int(count)).map { NSStringFromSelector(method_getName(methods[$0])) }
        free(methods)
        check(selectors.contains("safeAreaInsets") && selectors.contains("safeAreaRect") && !selectors.contains("safeAreaLayoutGuide"),"production host overrides only the two public safe-area getters")

        let counter=NativeProbeCounter(),session=ProbeDragSession()
        var receivedItems=[NSDraggingItem](),receivedEvent:NSEvent?,receivedSource:AnyObject?,snapshottedView:NSView?,snapshottedRect:CGRect = .zero
        let icon=SettingsAccessoryAssets.applicationIcon(bundleURL:fixture)
        let native=SettingsAccessoryDraggableView(applicationName:"Owned C77",applicationBundleURL:URL(string:"file:///tmp/Owned%20C77.app")!,icon:icon,
            destination:.privacyAccessibility,hintArrow:SettingsAccessoryAssets.hintArrow,beginSession:{ items,event,source in
                receivedItems=items;receivedEvent=event;receivedSource=source as AnyObject
                return session
            },currentBundleURL:{counter.increment();return URL(string:"file:///tmp/Fallback.app")!},snapshot:{ view,rect in
                snapshottedView=view;snapshottedRect=rect
                return SettingsAccessoryViewSnapshot.image(of:view,in:rect)
            })
        let owned=NSWindow(contentRect:CGRect(x:0,y:0,width:469,height:110),styleMask:.borderless,backing:.buffered,defer:false)
        owned.isReleasedWhenClosed=false;owned.contentView=native
        defer { owned.close() }
        native.layoutSubtreeIfNeeded();native.box.layoutSubtreeIfNeeded();native.appRowView.layoutSubtreeIfNeeded()
        check(native.registeredDraggedTypes == [.fileURL] && native.acceptsFirstMouse(for:nil),"native drag column registers file URLs and accepts first mouse")
        check(native.box.boxType == .custom && native.box.titlePosition == .noTitle && native.box.cornerRadius==7 && native.box.contentViewMargins==NSSize(width:4,height:5),"native column uses its NSBox and content margins")
        check(native.box.frame==CGRect(x:0,y:20,width:459,height:42) && native.box.contentView === native.appRowView,"native box constraints place the actual icon/name host at bottom20 height42 trailing10")
        check(native.hintView.frame.minX==4 && abs(native.hintView.frame.minY-native.box.frame.maxY-7)<0.01,"native hint is leading4 and seven points above the box")
        for (appearance,alpha) in [(NSAppearance.Name.aqua,0.65),(.darkAqua,0.06)] {
            native.appearance=NSAppearance(named:appearance)
            native.viewDidChangeEffectiveAppearance()
            check(abs(native.box.fillColor.alphaComponent-alpha)<1e-8,"native box updates the fill alpha for \(appearance.rawValue)")
        }
        let event=NSEvent.mouseEvent(with:.leftMouseDown,location:CGPoint(x:380,y:95),modifierFlags:[],timestamp:1,windowNumber:owned.windowNumber,context:nil,eventNumber:11,clickCount:1,pressure:1)!
        native.mouseDown(with:event)
        check(receivedItems.count==1 && receivedEvent === event && receivedSource === native,"mouseDown forwards the actual owned event and source to one drag session")
        check(snapshottedView === native.appRowView && snapshottedRect==native.appRowView.bounds,"mouseDown snapshots the whole actual icon/name row")
        let dragging=receivedItems[0]
        check(dragging.draggingFrame==native.convert(native.appRowView.bounds,from:native.appRowView) && dragging.draggingFrame.width>400 && dragging.draggingFrame.size != CGSize(width:32,height:32),"drag image frame comes from the full row and ignores the cursor location")
        check(session.animatesToStartingPositionsOnCancelOrFail && !native.appRowView.isHidden,"cancel/failure return animation is set after session creation, before willBegin")
        check((dragging.item as? NSPasteboardItem)?.types == [.fileURL],"drag data is declared lazily through a real pasteboard item")
        check(native.sourceOperation(for:.withinApplication) == .copy && native.sourceOperation(for:.outsideApplication) == .copy,"both native drag contexts advertise copy only")
        let delegate=ProbeDropDelegate();delegate.source=native;native.dragDelegate=delegate
        native.dragWillBegin();native.dragDidEnd(at:CGPoint(x:11,y:22),operation:.copy)
        check(delegate.drops==[CGPoint(x:11,y:22)] && delegate.hiddenDuringDrop==[true] && !native.appRowView.isHidden,"copy callback precedes revealing the row")
        for operation in [NSDragOperation(),.move,.copy.union(.move)] { native.dragWillBegin();native.dragDidEnd(at:.zero,operation:operation) }
        check(delegate.drops.count==1 && !native.appRowView.isHidden,"non-exact-copy masks restore the row without a drop callback")
        weak var weakDelegate:ProbeDropDelegate?
        do { let temporary=ProbeDropDelegate();weakDelegate=temporary;native.dragDelegate=temporary }
        check(weakDelegate==nil && native.dragDelegate==nil,"native drag delegate ownership is weak")
        native.dragWillBegin();native.dragDidEnd(at:.zero,operation:.copy)
        check(!native.appRowView.isHidden,"a missing delegate still restores the row")
        let board=NSPasteboard(name:.init("test.acua.c77."+UUID().uuidString))
        board.declareTypes([.fileURL],owner:nil)
        defer { board.releaseGlobally() }
        let ignoredItem=NSPasteboardItem()
        native.pasteboard(board,item:ignoredItem,provideDataForType:.string)
        check(board.data(forType:.fileURL)==nil && counter.value==0,"unsupported requested types neither write nor resolve the fallback URL")
        native.pasteboard(board,item:ignoredItem,provideDataForType:.fileURL)
        check(board.data(forType:.fileURL)==Data("file:///tmp/Owned%20C77.app".utf8) && ignoredItem.types.isEmpty && counter.value==0,"data provider writes URL bytes to the supplied private pasteboard, not the ignored item")
        let fallbackCount=NativeProbeCounter()
        let fallback=SettingsAccessoryDraggableView(applicationName:"Fallback",applicationBundleURL:nil,icon:icon,destination:nil,hintArrow:nil,currentBundleURL:{fallbackCount.increment();return URL(string:"file:///tmp/Fallback.app")!})
        fallback.pasteboard(nil,item:ignoredItem,provideDataForType:.fileURL)
        check(fallbackCount.value==1,"supported nil pasteboard still resolves the optional current-app fallback")
        fallback.pasteboard(board,item:ignoredItem,provideDataForType:.fileURL)
        check(fallbackCount.value==2 && board.data(forType:.fileURL)==Data("file:///tmp/Fallback.app".utf8),"absent explicit URL uses the current-app URL on demand")
        let missing=SettingsAccessoryDraggableView(applicationName:"Missing",applicationBundleURL:nil,icon:icon,destination:nil,hintArrow:nil,currentBundleURL:{nil})
        missing.pasteboard(board,item:ignoredItem,provideDataForType:.fileURL)
        check(board.data(forType:.fileURL)==Data("file:///tmp/Fallback.app".utf8),"missing explicit/current URL preserves existing pasteboard data")
        let semaphore=DispatchSemaphore(value:0),backgroundResult=NativeProbeCounter()
        DispatchQueue.global().async {
            let background=NSPasteboard(name:.init("test.acua.c77.background."+UUID().uuidString))
            background.declareTypes([.fileURL],owner:nil)
            native.pasteboard(background,item:NSPasteboardItem(),provideDataForType:.fileURL)
            if !Thread.isMainThread && background.data(forType:.fileURL)==Data("file:///tmp/Owned%20C77.app".utf8) { backgroundResult.increment() }
            background.releaseGlobally();semaphore.signal()
        }
        check(semaphore.wait(timeout:.now()+5) == .success && backgroundResult.value==1,"nonisolated data-provider callback runs on a background thread without a main-actor hop")
        check(SettingsAccessoryViewSnapshot.image(of:NoBitmapView(),in:CGRect(x:0,y:0,width:40,height:20))==nil,"unavailable bitmap caching returns a nil image")
        let nilSession=ProbeDragSession();var nilImageBegan=false
        let nilImage=SettingsAccessoryDraggableView(applicationName:"No image",applicationBundleURL:fixture,icon:icon,destination:nil,hintArrow:nil,beginSession:{ items,_,_ in nilImageBegan=items.count==1;return nilSession },snapshot:{_,_ in nil})
        nilImage.frame=CGRect(x:0,y:0,width:469,height:110);nilImage.layoutSubtreeIfNeeded();nilImage.mouseDown(with:event)
        check(nilImageBegan && nilSession.animatesToStartingPositionsOnCancelOrFail,"nil row image does not suppress creation of the drag session")
        let image=SettingsAccessoryViewSnapshot.image(of:native.appRowView,in:native.appRowView.bounds)!
        check(image.size==native.appRowView.bounds.size,"view-owned row snapshot retains point size and its bitmap representation")
        let rectangle=SettingsAccessoryLayout.contentFrame(windowQuartz:CGRect(x:200,y:100,width:700,height:650),primaryScreenHeight:1200,fittingSize:CGSize(width:531,height:110),audioHeading:CGRect(x:0,y:40,width:100,height:20))
        check(rectangle==CGRect(x:359,y:960,width:531,height:110),"production layout consumes window-relative audio heading bounds")
        let quartz=CGRect(x:200,y:100,width:700,height:650)
        check(SettingsAccessoryLayout.acceptsDrop(CGPoint(x:200,y:1100),windowQuartz:quartz,primaryScreenHeight:1200) && !SettingsAccessoryLayout.acceptsDrop(CGPoint(x:900,y:1100),windowQuartz:quartz,primaryScreenHeight:1200),"drop containment uses the Quartz transform and half-open edge")
        check(callbacks==0 && !panel.isVisible && !arrow.isVisible && !owned.isVisible,"all actual production/window/drag checks remain hidden and invoke no external action")
        wrapped.close()
        check((panel.childWindows ?? []).isEmpty && arrow.parent==nil,"live presentation cleanup closes and detaches the actual arrow")
        observations.merge(["nativeRowFrame":NSStringFromRect(native.appRowView.frame),"nativeDragFrame":NSStringFromRect(dragging.draggingFrame),"accessoryFrame":NSStringFromRect(panel.frame),"hidesOnDeactivate":defaultHides,"releasedWhenClosed":defaultReleased],uniquingKeysWith: { _,new in new })
        let passed=rows.allSatisfy { $0["passed"] as? Bool == true }
        let result:[String:Any]=["passed":passed,"cases":rows.count,"results":rows,"observations":observations,"actualProductionAccessoryConstructorExecuted":true,"ownedHiddenWindowsAndViewBitmapRenderingExecuted":true,"ownedPrivatePasteboardsOnly":true,"nativeDragSessionExecuted":false,"eventPostedOrWindowShownOrScreenCaptureExecuted":false,"originalNativeWindowOrDragExecuted":false]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("result.json"))
        if !passed { throw NSError(domain:"OwnedSettingsAccessoryNativeChecks",code:1) }
    }
}
