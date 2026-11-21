import Foundation
import AppKit
import ApplicationServices

@MainActor struct EventStreamSelectionMetadataIO {
    var runningApplicationName:(Int32)->String?
    var secureInputPID:()->Int?
    var runningApplicationBundleIdentifier:(Int32)->String?
    var desktopIconLevel:()->Int
    var cachedWindowTitle:(EventStreamAXNode)->String?
    static var native:Self {
        .init(runningApplicationName:{NSRunningApplication(processIdentifier:$0)?.localizedName},
            secureInputPID:{(CGSessionCopyCurrentDictionary() as? [String:Any])?["kCGSSessionSecureInputPID"] as? Int},
            runningApplicationBundleIdentifier:{NSRunningApplication(processIdentifier:$0)?.bundleIdentifier},
            desktopIconLevel:{Int(CGWindowLevelForKey(.desktopIconWindow))},
            cachedWindowTitle:{$0.cachedAttribute("AXTitle") as? String})
    }
}

@MainActor enum EventStreamSelectionMetadata {
    struct Snapshot {
        let app:EventStreamApp
        let window:EventStreamWindow
    }
    // Every read uses the selected CG owner's PID; nil
    // names do not prevent emitting the app identity or remaining metadata.
    static func snapshot(_ selection:EventStreamNativeSystemSelection,
                         io:EventStreamSelectionMetadataIO?=nil)->Snapshot {
        snapshot(window:selection.applicationWindow,url:selection.url,io:io)
    }
    static func snapshot(window:EventStreamNativeSelectionWindow,url:URL?,
                         io:EventStreamSelectionMetadataIO?=nil)->Snapshot {
        let io=io ?? .native
        let cg=window.nativeWindow,pid=cg.processIdentifier
        // appName falls back only for nil, before empty filtering.
        let name=nonempty(io.runningApplicationName(pid) ?? cg.ownerName)
        let secureInput=io.secureInputPID()==Int(pid)
        let bundle=nonempty(io.runningApplicationBundleIdentifier(pid))
        // This fallback is evaluated before AccessibilityNode's cached title.
        let fallback=applicationWindowTitle(window,io:io)
        let title=nonempty(io.cachedWindowTitle(window.window)) ?? nonempty(fallback)
        return .init(app:.init(name:name,secureInput:secureInput,processIdentifier:pid,bundleIdentifier:bundle),
            window:.init(title:title,url:url?.absoluteString,windowID:cg.id))
    }
    // ApplicationWindow.title: a present empty CG title does not
    // fall through to cached AX here; the recorder's subsequent getter does.
    static func applicationWindowTitle(_ window:EventStreamNativeSelectionWindow,
                                       io:EventStreamSelectionMetadataIO?=nil)->String? {
        let io=io ?? .native
        let cg=window.nativeWindow
        let candidate=cg.title ?? io.cachedWindowTitle(window.window)
        if let candidate,!candidate.isEmpty {return candidate}
        if cg.level==io.desktopIconLevel(),io.runningApplicationBundleIdentifier(cg.processIdentifier)=="com.apple.finder" {return "Desktop"}
        return candidate
    }
    private static func nonempty(_ value:String?)->String? {value.flatMap {$0.isEmpty ? nil:$0}}
}
