import AppKit
import ScreenCaptureKit

@MainActor enum PIPNativeCaptureFactory {
    typealias Factory = PIPCaptureFactory<SCWindow, SCDisplay, ControllerWindowDescription, SCContentFilter, SCStreamConfiguration>
    static func make(content: SCShareableContent, windowID: UInt32, associatedWindowIDs: [UInt32]) throws -> Factory.Result {
        let environment = Factory.Environment(windows: { content.windows }, displays: { content.displays },
            windowID: { $0.windowID }, windowFrame: { $0.frame }, isOnScreen: { $0.isOnScreen },
            hasOwner: { $0.owningApplication != nil }, processIdentifier: { $0.owningApplication?.processID },
            source: { ControllerWindowDescription.lookup($0) }, bounds: { $0.bounds },
            scale: { PIPCaptureScreenSelection.nativeScale(for: $0.bounds) },
            displayFrame: { $0.frame }, displayID: { $0.displayID },
            independentFilter: { SCContentFilter(desktopIndependentWindow: $0) },
            displayFilter: { SCContentFilter(display: $0, including: $1) },
            pointPixelScale: { $0.pointPixelScale }, configuration: { PIPCaptureConfiguration.native(bounds: $0, scale: $1) })
        return try Factory(environment: environment).make(windowID: windowID, associatedWindowIDs: associatedWindowIDs)
    }
}
