import Foundation
import AppKit
import ApplicationServices

enum EventStreamRecorderPrefetchPolicy {
    // AX prefetch configuration. Missing/malformed fields keep prefetch
    // enabled; only explicit false or a nonempty blocked prefix disable it.
    static func enabled(bundleIdentifier:String?,configuration:[String:Any])->Bool {
        if configuration["ax_prefetch_enabled"] as? Bool == false {return false}
        guard let bundleIdentifier else {return true}
        let prefixes=configuration["ax_prefetch_disabled_bundle_ids"] as? [String] ?? []
        for prefix in prefixes {
            let trimmed=prefix.trimmingCharacters(in:.whitespacesAndNewlines)
            if !trimmed.isEmpty,bundleIdentifier.hasPrefix(trimmed) {return false}
        }
        return true
    }
}

@MainActor final class EventStreamNativeRecorderCaptureFactory {
    typealias Context=EventStreamCaptureContext<EventStreamAXNode>
    typealias Revision=EventStreamNativeTreeRevision.Revision
    private let snapshots:EventStreamNativeSnapshots
    private let configuration:()->[String:Any]
    private let metadataIO:EventStreamSelectionMetadataIO
    private let recordURL:(UInt32,URL?)->Void
    private let parent:EventStreamNativeSelectionExtractorBackend<NSObject>
    init(configuration:@escaping ()->[String:Any],snapshots:EventStreamNativeSnapshots?=nil,transactions:EventStreamNativeTransactions?=nil,
         metadataIO:EventStreamSelectionMetadataIO?=nil,recordURL:@escaping (UInt32,URL?)->Void) {
        let reader=snapshots ?? .init();self.snapshots=reader;self.configuration=configuration
        self.metadataIO=metadataIO ?? .native;self.recordURL=recordURL
        // The recorder passes performAccessibilityEnablement=false.
        // These guards prevent silently enabling a different unsupported route.
        self.parent = .init(enableAccessibility:{_,_,_ in preconditionFailure("Recorder acquisition never enables accessibility")},
            disable:{_ in preconditionFailure("Recorder cannot acquire an accessibility assertion")},snapshots:reader,transactions:transactions)
    }
    func prepare(_ source:Context)->Context {
        // ApplicationWindow owns captured AX window values before the main
        // transaction/prefetch override. Metadata must not hydrate after capture.
        .init(application:snapshots.node(source.application.element),window:snapshots.node(source.window.element),
            focusedElement:source.focusedElement,nativeWindow:source.nativeWindow)
    }
    func capture(_ source:Context,previous:Revision?)throws->EventStreamAXTreeCapture<Revision> {
        let bundle=snapshots.backend.bundleIdentifier(of:.init(element:source.application.element))
        let prefetch=EventStreamRecorderPrefetchPolicy.enabled(bundleIdentifier:bundle,configuration:configuration())
        let selection=try EventStreamTreeTransactions.$prefetchEnabled.withValue(prefetch) {
            try EventStreamNativeSelectionExtractor.extract(from:source,type:.eventStreamContext,
                cache:nil,previous:previous,rootOverride:nil,performAccessibilityEnablement:false,
                alwaysIncludeScreenshot:true,enableAXDiffing:true,backend:parent)
        }
        let io=metadataIO,recordURL=self.recordURL
        return .init(revision:selection.windowRevision,windowID:selection.applicationWindow.nativeWindow.id,metadata:{
            // Update URL state after rendering/baseline commit and
            // before sampling name, secure-input PID, bundle and cached title.
            recordURL(selection.applicationWindow.nativeWindow.id,selection.url)
            let result=EventStreamSelectionMetadata.snapshot(selection,io:io)
            return .init(app:result.app,window:result.window)
        })
    }
}

extension EventStreamNativeContext {
    // Complete ordinary AX captureTree binding. The recorder configuration
    // provider is explicit; its remote SDK/auth owner remains a producer concern.
    func makeNativeAXCapture(prefetchConfiguration:@escaping ()->[String:Any],
                             snapshots:EventStreamNativeSnapshots?=nil,
                             transactions:EventStreamNativeTransactions?=nil,
                             metadataIO:EventStreamSelectionMetadataIO?=nil)
        ->EventStreamAXCapture<EventStreamCaptureContext<EventStreamAXNode>,EventStreamNativeTreeRevision.Revision> {
        let resolver=self.resolver
        let factory=EventStreamNativeRecorderCaptureFactory(configuration:prefetchConfiguration,snapshots:snapshots,transactions:transactions,
            metadataIO:metadataIO,recordURL:{resolver.recordCapturedURL($1,for:$0)})
        return .init(resolveContext:{factory.prepare(try resolver.captureContext($0))},contextWindowID:{$0.nativeWindow.id},
            captureTree:{context,previous in try factory.capture(context,previous:previous)},
            render:{capture,mode,withoutRemovalSubtree,ignoreBudget in
                capture.revision.eventStreamDescription(mode == .fullTree ? .fullTree:.difference(from:.previous),
                    lineOptions:withoutRemovalSubtree ? [.withoutRemovalSubtree]:[],ignoreDifferenceLineBudget:ignoreBudget)
            })
    }
}
