import Foundation

private final class OwnedFileManager: FileManager, @unchecked Sendable {
    var requested = [String]()
    let owned = URL(fileURLWithPath: "/private/tmp/owned-service-group")
    override func containerURL(forSecurityApplicationGroupIdentifier identifier: String) -> URL? {
        requested.append(identifier); return owned
    }
}
@main enum ServiceGroupConfigurationChecks {
    static func main() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("cua-group-config-\(UUID().uuidString)")
        defer {try? FileManager.default.removeItem(at:root)}
        var count=0
        func check(_ condition:Bool,_ name:String){precondition(condition,name);count+=1}
        func bundle(_ label:String,_ group:Any?,format:PropertyListSerialization.PropertyListFormat = .xml)throws->Bundle {
            let app=root.appendingPathComponent(label+".app"),contents=app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at:contents,withIntermediateDirectories:true)
            var info:[String:Any]=["CFBundleIdentifier":"test.acua.group-checks."+label,"CFBundlePackageType":"APPL"]
            if let group {info["CUAApplicationGroupIdentifier"]=group}
            try PropertyListSerialization.data(fromPropertyList:info,format:format,options:0).write(to:contents.appendingPathComponent("Info.plist"))
            return Bundle(url:app)!
        }
        let legacy=try bundle("legacy",nil),own="KS98C89L5H.com.aex.computeruse"
        check(EventStreamStorageConfiguration.configuredApplicationGroupIdentifier(bundle:legacy)==nil,"unconfigured executable has no group")
        for (label,format) in [("xml",PropertyListSerialization.PropertyListFormat.xml),("binary",.binary)] {
            let current=try bundle(label,own,format:format),manager=OwnedFileManager()
            check(EventStreamStorageConfiguration.configuredApplicationGroupIdentifier(bundle:current)==own,"bundle group uses "+label+" metadata")
            check(EventStreamStorageConfiguration.nativeContainerURL(fileManager:manager,bundle:current)==manager.owned,"native container uses configured group")
            check(manager.requested==[own],"platform receives the package group")
            EventStreamStorageConfiguration.configureNative(fileManager:manager,bundle:current)
            check(EventStreamStorageConfiguration.rootDirectoryURL(for:.recordAndReplay)==manager.owned.appendingPathComponent("Library/Caches/ComputerUse/RecordAndReplay",isDirectory:true),"record/replay uses configured native container")
            check(EventStreamStorageConfiguration.rootDirectoryURL(for:.timeline)==manager.owned.appendingPathComponent("Library/Caches/ComputerUse/Timeline",isDirectory:true),"Timeline uses configured native container")
        }
        for (label,value) in [("disabled","" as Any),("invalid",7 as Any)] {
            let app=try bundle(label,value),manager=OwnedFileManager()
            check(EventStreamStorageConfiguration.configuredApplicationGroupIdentifier(bundle:app)==nil,"explicit unavailable metadata does not fall back")
            check(EventStreamStorageConfiguration.nativeContainerURL(fileManager:manager,bundle:app)==nil && manager.requested.isEmpty,"unavailable group does not query an unrelated container")
            EventStreamStorageConfiguration.configureNative(fileManager:manager,bundle:app)
            check(EventStreamStorageConfiguration.rootDirectoryURL(for:.recordAndReplay)==nil,"unavailable configured group disables storage")
        }
        print("Service group configuration: \(count) checks passed")
    }
}
