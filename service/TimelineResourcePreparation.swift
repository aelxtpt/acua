import Foundation

// The concrete owner constructs its settings cache before these helpers run;
// the cached-settings branch does no reload.
struct TimelineResourcePreparation {
    let eventStreamRootURL:URL?
    let configurationRootURL:URL
    let memoryExtensionURL:URL
    let loadInstructions:()throws->String

    func prepareStorage()throws {
        guard let eventStreamRootURL else{throw EventStreamRecordingStorageError.unavailable}
        try FileManager.default.createDirectory(at:eventStreamRootURL,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:configurationRootURL,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:memoryExtensionURL.appendingPathComponent("resources",isDirectory:true),withIntermediateDirectories:true)
    }
    func prepareMemory()throws {
        try FileManager.default.createDirectory(at:memoryExtensionURL,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:memoryExtensionURL.appendingPathComponent("resources",isDirectory:true),withIntermediateDirectories:true)
        let value=try loadInstructions()
        let destination=memoryExtensionURL.appendingPathComponent("instructions.md",isDirectory:false)
        if (try?String(contentsOf:destination,encoding:.utf8)) != value {
            try value.write(to:destination,atomically:true,encoding:.utf8)
        }
    }
}
