import Foundation

//0x10012E730 classifies a raw before/after pair; normalization is the caller's
// job. Multiple different change categories (or none) become replace_all.
enum TimelineObservationSettingsUpdateType:UInt8 {
    case replaceAll=0,changeDefaultApplicationBehavior=1,changeDefaultURLBehavior=2
    case includeApplication=3,excludeApplication=4,includeURL=5,excludeURL=6

    var telemetryValue:String {
        switch self {
        case .replaceAll:return "replace_all"
        case .changeDefaultApplicationBehavior:return "change_default_application_behavior"
        case .changeDefaultURLBehavior:return "change_default_url_behavior"
        case .includeApplication:return "include_application"
        case .excludeApplication:return "exclude_application"
        case .includeURL:return "include_url"
        case .excludeURL:return "exclude_url"
        }
    }
    static func classify(old:TimelineObservationSettings,new:TimelineObservationSettings)->Self {
        var changes=Set<UInt8>()
        if old.defaultApplicationBehavior != new.defaultApplicationBehavior {changes.insert(Self.changeDefaultApplicationBehavior.rawValue)}
        if old.defaultURLBehavior != new.defaultURLBehavior {changes.insert(Self.changeDefaultURLBehavior.rawValue)}
        let oldAllow=Set(old.allowlist),newAllow=Set(new.allowlist),oldBlock=Set(old.blocklist),newBlock=Set(new.blocklist)
        let included=newAllow.subtracting(oldAllow).union(oldBlock.subtracting(newBlock))
        let excluded=newBlock.subtracting(oldBlock).union(oldAllow.subtracting(newAllow))
        if included.contains(where:{$0.scope == .app}) {changes.insert(Self.includeApplication.rawValue)}
        if excluded.contains(where:{$0.scope == .app}) {changes.insert(Self.excludeApplication.rawValue)}
        if included.contains(where:{$0.scope == .url}) {changes.insert(Self.includeURL.rawValue)}
        if excluded.contains(where:{$0.scope == .url}) {changes.insert(Self.excludeURL.rawValue)}
        guard changes.count==1,let value=changes.first else{return .replaceAll}
        return Self(rawValue:value)!
    }
}
