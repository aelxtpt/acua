import AppKit
import CoreGraphics
import Foundation
import OSLog

enum ControllerFrontmostWindowNative {
    typealias Reader=ControllerFrontmostWindow<ControllerOwnerRunningApplication,ControllerNativeElementContext.Node>
    static func matchingWindowPIDs(_ rows:[[AnyHashable:Any]],menuLevel:()->Int32={CGWindowLevelForKey(.mainMenuWindow)},currentPID:()->Int32={getpid()})->[Int32] {
        rows.map{ControllerWindowDescription(info:$0)}.filter{$0.level < menuLevel() && $0.ownerPID != currentPID()}.map(\.ownerPID)
    }
    static var environment:Reader.Environment {
        let logger=Logger(subsystem:"local.cua",category:"FrontmostWindow")
        let context=ControllerNativeElementContext.shared(lookup:{_ in nil},log:{name,error in
            logger.debug("\(name,privacy:.public): \(String(describing:error),privacy:.public)")
        })
        let geometry=ControllerNativeGeometry(context:context,io:.init(lookup:{_ in nil}))
        return .init(runningApplication:{pid in NSRunningApplication(processIdentifier:pid).map{.init(application:$0)}},
            bundleIdentifier:{$0.application.bundleIdentifier},frontmostApplication:{NSWorkspace.shared.frontmostApplication.map{.init(application:$0)}},
            matchingWindowPIDs:{
                let rows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[AnyHashable:Any]] ?? []
                return matchingWindowPIDs(rows)
            },isRegular:{$0.application.activationPolicy == .regular},isHidden:{$0.application.isHidden},
            applicationNode:{context.application($0.application.processIdentifier)},primaryWindow:{context.context.primaryWindow($0)},
            localizedName:{$0.application.localizedName},windowTitle:{geometry.value("AXTitle",on:$0)})
    }
}
