import AppKit
import ScreenCaptureKit

@MainActor enum PIPNativeCursorCaptureFactory {
    static func make(content:SCShareableContent,windowID:UInt32,targetBounds:CGRect?) throws
        -> PIPCursorCaptureFactory<any PIPCaptureCursor,SCWindow,SCDisplay,SCContentFilter,SCStreamConfiguration>.Result? {
        try PIPCursorCaptureFactory(environment:.init(fallbackBounds:{ id in
            guard let window=ControllerWindowDescription.lookup(id) else { throw PIPCaptureFactoryError.sourceWindowUnavailable }
            let bounds=window.bounds
            _=PIPCaptureScreenSelection.nativeScale(for:bounds)
            return bounds
        },cursors:{PIPCursorRegistry.shared.allObjects},targetWindowID:{$0.pipTargetWindowID},
            isVisible:{$0.pipIsVisible},windowNumber:{$0.pipWindowNumber},windows:{content.windows},windowID:{$0.windowID},
            windowFrame:{$0.frame},displays:{content.displays},displayFrame:{$0.frame},displayID:{$0.displayID},
            filter:{SCContentFilter(display:$0,including:$1)},pointPixelScale:{$0.pointPixelScale},
            configuration:{PIPCaptureConfiguration.native(bounds:$0,scale:$1,opaque:false)}))
            .make(windowID:windowID,targetBounds:targetBounds)
    }
}
