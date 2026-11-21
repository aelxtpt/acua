import Foundation
import AppKit
import ApplicationServices

@MainActor enum EventStreamScreenshotContextPolicy {
    private static let ownBundleIdentifier="com.aex.computeruse"
    private static let stickerActions:Set<String>=["Add to Photos Library","Quick Look"]
    /// ACUA's own apps (`com.aex.computeruse` or `com.aex.computeruse.*`,
    /// case sensitive) never need screenshot context.
    private static func isExempt(_ bundle:String)->Bool {
        bundle==ownBundleIdentifier || bundle.hasPrefix(ownBundleIdentifier+".")
    }
    // The caller can force a screenshot. Otherwise use captured
    // role/identifier fields but fresh size/action descriptions.
    // Bundle queries are independent: the Messages check occurs after images.
    static func needed<Element>(_ tree:EventStreamCollectedTree<Element>,alwaysIncludeScreenshot:Bool=false,
                                bundleIdentifier:()->String?,uncachedSize:(Element)->CGSize?,
                                actionDescriptions:(Element)->[String])->Bool {
        if alwaysIncludeScreenshot {return true}
        if let bundle=bundleIdentifier(),isExempt(bundle) {return false}
        let nodes=tree.preorder.map(\.node)
        if nodes.count<=9 {return true}
        let images=nodes.filter {$0.role=="AXImage" || $0.roleDescription=="image" || $0.subrole=="AXTextAttachment"}
        for image in images {
            if let size=uncachedSize(image.element),size.width>100 && size.height>100 {return true}
        }
        if bundleIdentifier()=="com.apple.MobileSMS" {
            let stickers=nodes.filter {$0.role=="AXButton" && $0.identifier=="Sticker"}
            for sticker in stickers {
                if !Set(actionDescriptions(sticker.element)).isDisjoint(with:stickerActions) {return true}
            }
        }
        return false
    }
}

@MainActor struct EventStreamScreenshotContextIO {
    var bundleIdentifier:(EventStreamAXNode)->String?
    var uncachedSize:(EventStreamAXNode)->CGSize?
    var actionDescriptions:(EventStreamAXNode)->[String]
    static var native:Self {
        .init(bundleIdentifier:{application in
            var pid:pid_t = -1
            guard AXUIElementGetPid(application.element,&pid) == .success else {return nil}
            return NSRunningApplication(processIdentifier:pid)?.bundleIdentifier
        },uncachedSize:{node in
            var raw:CFTypeRef?
            let status=AXUIElementCopyAttributeValue(node.element,"AXSize" as CFString,&raw)
            guard [AXError.success,.noValue,.attributeUnsupported].contains(status),let raw,
                  CFGetTypeID(raw)==AXValueGetTypeID() else {return nil}
            let value=unsafeBitCast(raw,to:AXValue.self);var size=CGSize.zero
            guard AXValueGetType(value) == .cgSize,AXValueGetValue(value,.cgSize,&size) else {return nil}
            return size
        },actionDescriptions:{node in
            let backend=EventStreamNativeNodeBackend()
            return ((try? backend.actions(node)) ?? []).map {name in
                EventStreamNodeAction.predefinedDescription(name) ?? (try? backend.actionDescription(name,of:node)) ?? name
            }
        })
    }
}

@MainActor enum EventStreamNativeScreenshotContextPolicy {
    // Ordinary AX binding; hosted PID/I/O ownership remains a separate provider.
    static func needed(_ tree:EventStreamCollectedTree<EventStreamAXNode>,application:EventStreamAXNode,
                       alwaysIncludeScreenshot:Bool=false,io:EventStreamScreenshotContextIO?=nil)->Bool {
        let io=io ?? .native
        return EventStreamScreenshotContextPolicy.needed(tree,alwaysIncludeScreenshot:alwaysIncludeScreenshot,
            bundleIdentifier:{io.bundleIdentifier(application)},uncachedSize:io.uncachedSize,actionDescriptions:io.actionDescriptions)
    }
}
