import Foundation

// Write the supplied settings, without normalizing here. The
// service's update path performs normalization separately before this helper.
enum TimelineSettingsStorage {
    static func write(_ settings:TimelineSettings,configurationRootURL:URL)throws {
        try FileManager.default.createDirectory(at:configurationRootURL,withIntermediateDirectories:true)
        let encoder=JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted,.sortedKeys,.withoutEscapingSlashes]
        try encoder.encode(settings).write(to:configurationRootURL.appendingPathComponent("settings.json"),options:.atomic)
    }
    // The actual constructor and getSettings fallback decode, normalize and
    // cache defaults on either I/O, Codable or validation failure.
    static func load(configurationRootURL:URL)->TimelineSettings {
        do {
            let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
            var value=try decoder.decode(TimelineSettings.self,from:Data(contentsOf:configurationRootURL.appendingPathComponent("settings.json")))
            value.observation=try value.observation.normalized()
            return value
        }catch{return .init(observation:.defaults)}
    }
}

// Cached Timeline settings. Capture/session/memory
// and IPC integration are tracked separately. The owner serializes all access.
final class TimelineSettingsCache {
    struct Effects {
        var refreshCapture:()->Void={}
        var recordUpdate:(TimelineObservationSettingsUpdateType,TimelineSettings)->Void={_,_ in}
    }
    static let didChangeNotification=Notification.Name("timelineServiceSettingsDidChange")
    private var settings:TimelineSettings
    private let configurationRootURL:URL
    private let effects:Effects
    private weak var notificationObject:AnyObject?
    init(configurationRootURL:URL,notificationObject:AnyObject?=nil,effects:Effects = .init()) {
        self.configurationRootURL=configurationRootURL
        self.notificationObject=notificationObject
        self.effects=effects
        settings=TimelineSettingsStorage.load(configurationRootURL:configurationRootURL)
    }
    func get()->TimelineSettings{settings}
    func updateObservationPolicy(_ observe:Bool,forApplication bundleID:String)throws->TimelineSettings {
        guard !bundleID.isEmpty else{throw TimelineError.invalidApplicationRule}
        return try updatePolicy(observe,rule:.init(scope:.app,bundleID:bundleID),matches:{$0.matchesApplication(bundleIdentifier:bundleID)})
    }
    func updateObservationPolicy(_ observe:Bool,forURLDomain domain:String)throws->TimelineSettings {
        let normalized=domain.lowercased()
        guard !normalized.isEmpty else{throw TimelineError.invalidURLRule}
        // Remove opposite rules that match the target host. This
        // includes applicable parent domains, not just identical strings.
        return try updatePolicy(observe,rule:.init(scope:.url,urlDomain:normalized),matches:{$0.matches(host:normalized)})
    }
    private func updatePolicy(_ observe:Bool,rule:TimelineObservationRule,matches:(TimelineObservationRule)->Bool)throws->TimelineSettings {
        var value=settings
        if observe {
            value.observation.blocklist.removeAll(where:matches)
            if !value.observation.allowlist.contains(rule){value.observation.allowlist.append(rule)}
        }else {
            value.observation.allowlist.removeAll(where:matches)
            if !value.observation.blocklist.contains(rule){value.observation.blocklist.append(rule)}
        }
        return try update(value)
    }
    func update(_ input:TimelineSettings)throws->TimelineSettings {
        let old=settings
        let value=TimelineSettings(observation:try input.observation.normalized())
        try TimelineSettingsStorage.write(value,configurationRootURL:configurationRootURL)
        settings=value
        effects.refreshCapture()
        NotificationCenter.default.post(name:Self.didChangeNotification,object:notificationObject ?? self)
        effects.recordUpdate(.classify(old:old.observation,new:value.observation),value)
        return value
    }
}
