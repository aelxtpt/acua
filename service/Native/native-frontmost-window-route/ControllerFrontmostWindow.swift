import Foundation

struct ControllerFrontmostWindowResult:Codable,Equatable,Sendable {
    let bundleIdentifier:String
    let name:String
    let windowTitle:String?
    var json:JSON {
        var result:JSON=["bundleIdentifier":bundleIdentifier,"name":name]
        if let windowTitle{result["windowTitle"]=windowTitle}
        return result
    }
}

/// Sender bundle exclusions, eager fallback reads and
///primary-window/title extraction. No extra lock/permission/PID admission gate.
struct ControllerFrontmostWindow<Application:Sendable,Node:Sendable>:Sendable {
    struct Environment:Sendable {
        let runningApplication:@Sendable (Int32)->Application?
        let bundleIdentifier:@Sendable (Application)->String?
        let frontmostApplication:@Sendable ()->Application?
        let matchingWindowPIDs:@Sendable ()->[Int32]
        let isRegular:@Sendable (Application)->Bool
        let isHidden:@Sendable (Application)->Bool
        let applicationNode:@Sendable (Application)->Node
        let primaryWindow:@Sendable (Node)->Node?
        let localizedName:@Sendable (Application)->String?
        let windowTitle:@Sendable (Node)->String?
    }
    let environment:Environment
    func read(sender:SenderRequestContext?)->ControllerFrontmostWindowResult? {
        var excluded=Set<String>()
        if let sender {
            if let bundle=sender.responsibleIdentity?.bundleID{excluded.insert(bundle)}
            if let app=environment.runningApplication(sender.senderPID),let bundle=environment.bundleIdentifier(app){excluded.insert(bundle)}
        }
        let application:Application?
        if let current=environment.frontmostApplication(),let bundle=environment.bundleIdentifier(current),!excluded.contains(bundle) {
            application=current
        }else {
            // Preserve eager mapping, followed by eager filtering. Choosing one
            // result does not skip native property reads for later candidates.
            let running=environment.matchingWindowPIDs().compactMap(environment.runningApplication)
            let candidates=running.filter{app in
                guard let bundle=environment.bundleIdentifier(app),!excluded.contains(bundle),environment.isRegular(app) else{return false}
                return !environment.isHidden(app)
            }
            if let first=candidates.first,let bundle=environment.bundleIdentifier(first),!excluded.contains(bundle){application=first}
            else{application=nil}
        }
        guard let application,let bundle=environment.bundleIdentifier(application),!bundle.isEmpty else{return nil}
        let node=environment.applicationNode(application)
        let window=environment.primaryWindow(node)
        let name=environment.localizedName(application) ?? bundle
        guard let window else{return nil}
        return .init(bundleIdentifier:bundle,name:name,windowTitle:environment.windowTitle(window))
    }
}
