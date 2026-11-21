import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import ScreenCaptureKit

@MainActor
final class RemoteHostedPIPWindowRenderer: RemoteHostedPIPStreamRenderer {
    private let windowID: CGWindowID
    private var associatedWindowIDs: [CGWindowID]
    private let onFrame: (CVPixelBuffer) -> Void
    private let onCursorFrame: (CVPixelBuffer) -> Void
    private let layer = AVSampleBufferDisplayLayer()
    private let cursorLayer = AVSampleBufferDisplayLayer()
    private var stream: PIPCaptureStream?
    private let lifecycle = PIPRendererLifecycle()
    private var geometryUpdateTask: Task<Void, Never>?
    private let presentation = PIPPresentationState()
    private var sourceFrame: CGRect?
    private var captureGeometry: CaptureGeometry?
    private var geometryObserver: RemoteHostedPIPWindowGeometryObserver?
    private var windowFocus: RemoteHostedPIPWindowFocus?
    private var onGeometryChange: (() -> Void)?
    private var onResizeChanged: ((CGSize) -> Void)?
    private var onResizeSettled: ((CGSize) -> Void)?
    var emitsNativeGeometryResizeCallbacks:Bool { true }
    private var onSourceUnavailable: (() -> Void)?
    var diagnosticEventHandler: ((String) -> Void)?
    var diagnosticCursorLayoutHandler: ((PIPCursorLayerGeometry,CGRect?,CGRect,Bool) -> Void)?
    private var cursorWindowID: CGWindowID?
    private var cursorObserver: NSObjectProtocol?
    private typealias CursorPayload = (filter:SCContentFilter,configuration:SCStreamConfiguration)
    private lazy var cursorCapture:PIPCursorCaptureController<CursorPayload,PIPCaptureStream> = PIPCursorCaptureController<CursorPayload,PIPCaptureStream>(environment:.init(
        sourceUnavailable:{ [weak self] in self?.lifecycle.sourceUnavailable ?? true },
        advanceGeneration:{ [unowned self] in self.lifecycle.beginCursorCapture() },
        layout:{ [weak self] in self?.layoutCursor($0) },hideAndFlush:{ [weak self] in self?.hideAndFlushCursor() },
        makeCapture:{ [weak self] payload,generation in
            PIPCaptureStream(filter:payload.filter,configuration:payload.configuration,
                sampleHandler:{ [weak self] frame in
                    DispatchQueue.main.async { [weak self] in self?.deliverCursor(frame.sample,generation:generation) }
                },errorHandler:{ [weak self] _ in
                    DispatchQueue.main.async { [weak self] in
                        self?.cursorCaptureStopped(generation:generation)
                    }
                })
        },start:Self.startCursorStream,stop:Self.stopCursorStream))
    private static func startCursorStream(_ capture:PIPCaptureStream) async throws { try await capture.start() }
    private static func stopCursorStream(_ capture:PIPCaptureStream) async throws { try await capture.stop() }
    private(set) var sourceProcessIdentifier: Int32?

    init(windowID: CGWindowID, associatedWindowIDs: [CGWindowID],
         onCursorFrame: @escaping (CVPixelBuffer) -> Void = { _ in }, onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.windowID = windowID
        self.associatedWindowIDs = associatedWindowIDs
        self.onFrame = onFrame
        self.onCursorFrame = onCursorFrame
        layer.videoGravity = .resizeAspect
        cursorLayer.videoGravity = .resize
        cursorLayer.isHidden = true
    }

    func prepare(producer: RemoteHostedPIPContentProducer, isActive: Bool, maxDisplaySize: CGFloat) async throws -> CGSize {
        presentation.maximumDisplaySize = PIPPresentationAspectParser.normalizedMaximum(maxDisplaySize)
        let (plan, geometry) = try await capturePlan()
        sourceProcessIdentifier = plan.pid
        windowFocus = RemoteHostedPIPWindowFocus(windowID: windowID, expectedPID: plan.pid)
        sourceFrame=plan.frame;captureGeometry=geometry
        let fallback=PIPPresentationAspect(size:PIPPresentationAspectParser.fit(plan.frame.size,maximum:presentation.maximumDisplaySize),reason:"geometry-fallback",sourceSize:plan.frame.size)
        try await resize(producer:producer,isActive:isActive,size:fallback.size)
        try await replaceCapture(plan)
        let aspect=await presentation.wait(fallback:fallback,useCurrentCache:true,captureGeneration:lifecycle.captureGeneration)
        let size=aspect.size
        try await resize(producer: producer, isActive: isActive, size: size)
        installGeometryObserver()
        installCursorObserver()
        await refreshCursorCapture()
        return size
    }

    private struct CaptureGeometry: Equatable {
        let frame: CGRect
        let key: PIPCaptureKey
        func usesSameCapture(as other: Self) -> Bool { key == other.key }
    }

    private typealias CapturePlan = (filter: SCContentFilter, configuration: SCStreamConfiguration, frame: CGRect, pid: Int32?)

    private func replaceCapture(_ plan:CapturePlan) async throws {
        let generation=lifecycle.beginCapture()
        presentation.beginCapture(generation:generation)
        let previous=stream;stream=nil
        if let previous { try? await previous.stop() }
        let capture=PIPCaptureStream(filter:plan.filter,configuration:plan.configuration,
            sampleHandler:{ [weak self] frame in
                DispatchQueue.main.async { [weak self] in self?.deliver(frame.sample,generation:generation) }
            },errorHandler:{ [weak self] error in
                DispatchQueue.main.async { [weak self] in self?.captureStopped(generation:generation,error:error) }
            })
        stream=capture
        do { try await capture.start() }
        catch { if stream===capture { stream=nil;captureGeometry=nil };throw error }
    }

    private func installGeometryObserver() {
        geometryObserver = RemoteHostedPIPWindowGeometryObserver(windowID: windowID,
            onGeometryChanged: { [weak self] reason in self?.geometryChanged(reason: reason) },
            onSourceUnavailable: { [weak self] reason in self?.sourceUnavailable(reason: reason) })
    }

    private func geometryChanged(reason: String) {
        diagnosticEventHandler?("geometry:" + reason)
        guard let window = ControllerWindowDescription.lookup(windowID) else { sourceUnavailable(reason: reason); return }
        _ = PIPCaptureScreenSelection.nativeScale(for: window.bounds)
        geometryUpdateTask?.cancel()
        let generation = lifecycle.beginGeometryUpdate()
        geometryUpdateTask = Task { [weak self] in
            guard let self else { return }
            guard (try? await Task.sleep(for: .milliseconds(240))) != nil,
                  !Task.isCancelled, self.lifecycle.geometryIsCurrent(generation) else { return }
            await self.updateGeometry(generation:generation)
            self.diagnosticEventHandler?("geometry-update:end")
            self.onGeometryChange?()
        }
    }

    private func captureStopped(generation: Int, error: any Error) {
        guard lifecycle.captureIsCurrent(generation) else { return }
        sourceUnavailable(reason: "capture-stream-stopped")
    }

    private func hideAndFlushCursor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.isHidden = true
        cursorLayer.flush()
        CATransaction.commit()
        CATransaction.flush()
    }

    private func sourceUnavailable(reason: String) {
        lifecycle.markSourceUnavailable(cancelGeometry: {
            geometryUpdateTask?.cancel()
            geometryUpdateTask = nil
        }, flushDisplay: { layer.flush() }, hideCursor: { hideAndFlushCursor() }, detachCursor: {
            let previous = cursorCapture.detach()
            Task { if let previous { try? await previous.stop() } }
        }, resolvePresentation: { presentation.resolveFallback(reason: reason) }, notify: {
            diagnosticEventHandler?("unavailable:" + reason)
            onSourceUnavailable?()
        })
    }

    var nativeAssociatedWindowUpdate: (([CGWindowID])->Void)? {setAssociatedWindowIDs}
    func setAssociatedWindowIDs(_ ids:[CGWindowID]) {
        PIPAssociatedWindowState.update(ids,current:{ [self] in associatedWindowIDs },
            store:{ [self] in associatedWindowIDs=$0 },forward:{ [self] _ in
                if stream != nil {geometryChanged(reason:"associated-windows")}
            })
    }

    // Legacy direct renderer clients retain their explicit post-update callback.
    // Normal ContentStream uses the two native resize callbacks below.
    func setGeometryChangeHandler(_ handler: @escaping () -> Void) {
        onGeometryChange=handler
        if onResizeSettled==nil { onResizeSettled={ [weak self] _ in self?.setFrameDeliverySuspended(false) } }
    }
    func setGeometryResizeHandlers(changed:@escaping(CGSize)->Void,settled:@escaping(CGSize)->Void) {
        onResizeChanged=changed;onResizeSettled=settled
    }
    func setFrameDeliverySuspended(_ value:Bool) {
        if value { lifecycle.suspendDelivery { layer.flush() } } else { lifecycle.resumeDelivery() }
    }
    func setSourceUnavailableHandler(_ handler: @escaping () -> Void) { onSourceUnavailable = handler }

    func focusPresentation() {
        windowFocus?.toggle()
    }

    func refreshGeometry() async throws {
        await updateGeometry(generation:lifecycle.geometryGeneration)
    }

    private func updateGeometry(generation:Int) async {
        let transition=PIPGeometryTransition<CapturePlan>(environment:.init(
            isCurrent:{ [self] in lifecycle.geometryIsCurrent($0) },isCancelled:{Task.isCancelled},
            bounds:{ [self] in sourceFrame },setBounds:{ [self] in sourceFrame=$0 },key:{ [self] in captureGeometry?.key },
            setKey:{ [self] in captureGeometry = .init(frame:$0.bounds,key:$0.key) },
            suspended:{ [self] in lifecycle.frameDeliverySuspended },suspend:{ [self] in lifecycle.suspendDelivery {layer.flush()} },
            resume:{ [self] in lifecycle.resumeDelivery() },currentSize:{ [self] in presentation.currentSize },maximum:{ [self] in presentation.maximumDisplaySize },
            configure:{ [self] in let (plan,geometry)=try await capturePlan();return .init(key:geometry.key,bounds:geometry.frame,payload:plan) },
            replace:{ [self] in try await replaceCapture($0) },
            wait:{ [self] in await presentation.wait(fallback:$0,useCurrentCache:false,captureGeneration:lifecycle.captureGeneration) },
            changed:{ [self] in onResizeChanged?($0) },settled:{ [self] in onResizeSettled?($0) },
            refreshCursor:{ [self] in await refreshCursorCapture() },unavailable:{ [self] in sourceUnavailable(reason:$0) },
            recordError:{ [self] in diagnosticEventHandler?("geometry-error:"+String(reflecting:$0)) }))
        await transition.update(generation:generation)
    }

    private func capturePlan() async throws -> (CapturePlan, CaptureGeometry) {
        let result=try await PIPAssociatedWindowState.configure(
            fetch:{try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)},
            ids:{ [self] in associatedWindowIDs },
            make:{ [self] content,ids in try PIPNativeCaptureFactory.make(content:content,windowID:windowID,associatedWindowIDs:ids) })
        // PID publication is a compatibility API outside the capture key.
        let plan:CapturePlan=(result.filter,result.configuration,result.targetBounds,result.primary.owningApplication?.processID)
        return (plan,.init(frame:result.targetBounds,key:result.key))
    }

    func presentationSize(forMaxDisplaySize size: CGFloat) -> CGSize {
        presentation.updateMaximum(size, targetBounds: sourceFrame, captureGeneration: lifecycle.captureGeneration)
    }

    func resize(producer: RemoteHostedPIPContentProducer, isActive: Bool, size: CGSize) async throws {
        PIPNativeLayerLayout.apply(size:size,root:producer.rootLayer,video:layer,cursor:cursorLayer,
            hasCursorGeometry:cursorCapture.geometry != nil,layoutCursor:{ [self] in layoutCursor() })
    }

    func stop() async {
        windowFocus = nil
        geometryUpdateTask?.cancel()
        geometryUpdateTask = nil
        if let cursorObserver { NotificationCenter.default.removeObserver(cursorObserver);self.cursorObserver=nil }
        presentation.cancelTimeout()
        lifecycle.invalidateGenerations()
        presentation.resolveFallback(reason: "stop-fallback")
        geometryObserver = nil
        let previous = stream
        stream = nil
        captureGeometry = nil
        let previousCursor = cursorCapture.detach()
        hideAndFlushCursor()
        // Await the main capture stop, then the cursor stop, independently ignoring
        // failures. Source loss above intentionally leaves main capture intact.
        if let previous { try? await previous.stop() }
        if let previousCursor { try? await previousCursor.stop() }
    }

    private func deliver(_ sample: CMSampleBuffer, generation: Int) {
        guard lifecycle.captureIsCurrent(generation) else { return }
        if let aspect = PIPPresentationAspectParser.native(sample, maximum: presentation.maximumDisplaySize) {
            presentation.record(aspect, generation: generation)
        }
        if !lifecycle.frameDeliverySuspended {
            if let buffer = sample.imageBuffer { onFrame(buffer) }
            layer.sampleBufferRenderer.enqueue(sample)
        }
    }

    func setCursorWindowID(_ id: CGWindowID?) {
        guard id != cursorWindowID else { return }
        cursorWindowID = id
        restartCursorCapture()
    }

    private func installCursorObserver() {
        guard cursorObserver==nil else { return }
        cursorObserver=NotificationCenter.default.addObserver(forName:PIPCursorRegistry.didFinishMove,object:nil,queue:.main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,PIPCursorRegistry.notificationMatches(notification.object,windowID:self.windowID) else { return }
                Task { @MainActor [weak self] in await self?.refreshCursorCapture() }
            }
        }
    }

    private func restartCursorCapture() {
        Task { @MainActor [weak self] in await self?.refreshCursorCapture() }
    }

    private func refreshCursorCapture() async {
        diagnosticEventHandler?("cursor-refresh:begin")
        defer { diagnosticEventHandler?("cursor-refresh:end") }
        await cursorCapture.refresh {
            let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:false)
            guard let result=try PIPNativeCursorCaptureFactory.make(content:content,windowID:windowID,targetBounds:sourceFrame) else { return nil }
            return .init(payload:(result.filter,result.configuration),key:result.key,geometry:result.geometry)
        }
    }

    private func cursorCaptureStopped(generation:Int) {
        guard lifecycle.cursorIsCurrent(generation) else { return }
        Task { @MainActor [weak self] in await self?.cursorCapture.clear() }
    }

    private func deliverCursor(_ sample: CMSampleBuffer,generation:Int) {
        guard lifecycle.cursorIsCurrent(generation),!cursorLayer.isHidden else { return }
        cursorLayer.sampleBufferRenderer.enqueue(sample)
        if let pixels=sample.imageBuffer { onCursorFrame(pixels) }
    }

    private func layoutCursor(_ geometry:PIPCursorLayerGeometry) {
        switch geometry.layout(superlayerBounds:cursorLayer.superlayer?.bounds) {
        case .unchanged:return
        case .hidden:hideAndFlushCursor()
        case let .frame(frame):
            CATransaction.begin();CATransaction.setDisableActions(true)
            cursorLayer.frame=frame;cursorLayer.isHidden=false
            CATransaction.commit();CATransaction.flush()
            diagnosticCursorLayoutHandler?(geometry,sourceFrame,cursorLayer.frame,cursorLayer.isHidden)
        }
    }
    private func layoutCursor() { if let geometry=cursorCapture.geometry { layoutCursor(geometry) } }


}

extension RemoteHostedPIPContentPublisher {
    func publishWindowStream(threadID: String, turnID: String, windowID: CGWindowID,
                             associatedWindowIDs: [CGWindowID] = [],
                             onFrame: @escaping (CVPixelBuffer) -> Void = { _ in }) -> RemoteHostedPIPContentStream {
        let stream = RemoteHostedPIPContentStream(publisher: self, threadID: threadID, turnID: turnID) { publishFrame in
            RemoteHostedPIPWindowRenderer(windowID: windowID, associatedWindowIDs: []) { frame in
                publishFrame(frame)
                onFrame(frame)
            }
        }
        stream.setAssociatedWindowIDs(associatedWindowIDs)
        registerExistingStream(stream)
        return stream
    }
}

extension RemoteHostedPIPWindowRenderer {
    struct DiagnosticState: Sendable {
        let geometryGeneration: Int
        let captureGeneration: Int
        let cursorGeneration: Int
        let sourceUnavailable: Bool
        let frameDeliverySuspended: Bool
        let cursorHidden: Bool
        let hasMainCapture: Bool
        let hasCaptureGeometry: Bool
        let hasGeometryObserver: Bool
        let currentPresentationSize: CGSize?
        let latestPresentationAspect: PIPPresentationAspect?
        let latestAspectGeneration: Int
        let hasPendingPresentation: Bool
        let captureKey: PIPCaptureKey?
        let cursorCaptureKey: PIPCursorCaptureKey?
        let hasCursorCapture: Bool
        let cursorLayerGeometry: PIPCursorLayerGeometry?
        let targetBounds: CGRect?
        let hasCursorObserver:Bool
    }
    var diagnosticAssociatedWindowIDs:[CGWindowID] {associatedWindowIDs}
    var diagnosticState: DiagnosticState {
        .init(geometryGeneration:lifecycle.geometryGeneration,captureGeneration:lifecycle.captureGeneration,
            cursorGeneration:lifecycle.cursorGeneration,sourceUnavailable:lifecycle.sourceUnavailable,
            frameDeliverySuspended:lifecycle.frameDeliverySuspended,cursorHidden:cursorLayer.isHidden,
            hasMainCapture:stream != nil,hasCaptureGeometry:captureGeometry != nil,hasGeometryObserver:geometryObserver != nil,
            currentPresentationSize:presentation.currentSize,latestPresentationAspect:presentation.latest,
            latestAspectGeneration:presentation.latestGeneration,hasPendingPresentation:presentation.hasPendingWaiter,captureKey:captureGeometry?.key,cursorCaptureKey:cursorCapture.key,hasCursorCapture:cursorCapture.capture != nil,cursorLayerGeometry:cursorCapture.geometry,targetBounds:sourceFrame,hasCursorObserver:cursorObserver != nil)
    }
    func diagnosticAttachCursorLayer(to root:CALayer) { root.addSublayer(cursorLayer) }
    func diagnosticRefreshCursorCapture() async { await refreshCursorCapture() }
    func diagnosticInstallCursorObserver() { installCursorObserver() }

    func diagnosticBeginCapture() async throws {
        let (plan,geometry) = try await capturePlan()
        sourceProcessIdentifier = plan.pid
        sourceFrame=plan.frame;captureGeometry=geometry
        try await replaceCapture(plan)
        let fallback=PIPPresentationAspect(size:PIPPresentationAspectParser.fit(plan.frame.size,maximum:presentation.maximumDisplaySize),reason:"geometry-fallback",sourceSize:plan.frame.size)
        _=await presentation.wait(fallback:fallback,useCurrentCache:true,captureGeneration:lifecycle.captureGeneration)
        installGeometryObserver()
    }
    func diagnosticSourceUnavailable(_ reason:String) { sourceUnavailable(reason:reason) }
    func diagnosticDeliver(_ sample:CMSampleBuffer,generation:Int) { deliver(sample,generation:generation) }
    func diagnosticCaptureStopped(generation:Int,error:any Error) { captureStopped(generation:generation,error:error) }
}
