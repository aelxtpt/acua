import Foundation

extension TimelineObservationSettings {
    func excludesApplication(bundleIdentifier:String?)->Bool {
        if blocklist.contains(where:{$0.matchesApplication(bundleIdentifier:bundleIdentifier)}){return true}
        if allowlist.contains(where:{$0.matchesApplication(bundleIdentifier:bundleIdentifier)}){return false}
        return defaultApplicationBehavior == .doNotObserve
    }
    func excludesHost(_ host:String)->Bool {
        if blocklist.contains(where:{$0.matches(host:host)}){return true}
        if allowlist.contains(where:{$0.matches(host:host)}){return false}
        return defaultURLBehavior == .doNotObserve
    }
}
enum TimelineObservationSuppressionReason {case applicationExcluded,privateBrowsingExcluded,urlExcluded,urlPolicyBlocked}
struct TimelineRecordClassification {
    var application:EventStreamObservedApplication?
    var urlDomain:String?
    var suppressionReason:TimelineObservationSuppressionReason?
}
@MainActor final class TimelineRecordClassifier {
    private let settings:()->TimelineSettings
    private let resolver:EventStreamApplicationResolver
    private let filter:any EventStreamRecordFilter
    init(settings:@escaping ()->TimelineSettings,resolver:EventStreamApplicationResolver,filter:any EventStreamRecordFilter){self.settings=settings;self.resolver=resolver;self.filter=filter}
    func classify(_ record:EventStreamRecord)async->TimelineRecordClassification {
        let observation=settings().observation
        let application=record.app.flatMap(resolver.resolve)
        let isPrivate=TimelinePrivateBrowsingIndicators.isPrivateBrowserWindow(bundleIdentifier:record.app?.bundleIdentifier,title:record.window?.title)
        let host:String?
        if let app=record.app,resolver.isWebBrowser(app),let text=record.window?.url,let url=URL(string:text),url.scheme=="http" || url.scheme=="https" {host=url.host?.lowercased()}
        else{host=nil}
        var reason:TimelineObservationSuppressionReason?
        if isPrivate{reason = .privateBrowsingExcluded}
        else if observation.excludesApplication(bundleIdentifier:application?.bundleIdentifier){reason = .applicationExcluded}
        else if let host,observation.excludesHost(host){reason = .urlExcluded}
        else if host != nil,case .blocked = await filter.disposition(for:record){reason = .urlPolicyBlocked}
        return .init(application:application,urlDomain:host,suppressionReason:reason)
    }
}
struct TimelineApplicationSession {var application:EventStreamObservedApplication;var startedAt:Date;var endedAt:Date?}
struct TimelineRecentURLDomain {var domain:String;var isExcluded:Bool;var lastSeenAt:Date}
struct TimelineRecentApplication {
    var application:EventStreamObservedApplication
    var lastSession:TimelineApplicationSession
    var urlDomains:[TimelineRecentURLDomain]
    var isExcluded:Bool
    var lastSeenAt:Date
}
@MainActor final class TimelineRecentApplicationStore {
    private(set) var entries=[TimelineRecentApplication]()
    func reset(){entries=[]}
    func removeEntries(in intervals: [DateInterval]) {
        entries.removeAll { entry in intervals.contains { $0.contains(entry.lastSeenAt) } }
    }

    func snapshot(now: Date, observation: TimelineObservationSettings) -> [TimelineRecentApplication] {
        let cutoff = now.addingTimeInterval(-600)
        entries.removeAll { $0.lastSeenAt < cutoff }
        for index in entries.indices {
            entries[index].urlDomains.removeAll { $0.lastSeenAt < cutoff }
        }
        return entries.compactMap { stored in
            guard !Self.hidden(stored.application) else { return nil }
            var entry = stored
            entry.isExcluded = observation.excludesApplication(bundleIdentifier: entry.application.bundleIdentifier)
            for index in entry.urlDomains.indices {
                entry.urlDomains[index].isExcluded = observation.excludesHost(entry.urlDomains[index].domain)
            }
            return entry
        }
    }

    private static func hidden(_ application: EventStreamObservedApplication) -> Bool {
        let id = application.bundleIdentifier
        if let id, id == Bundle.main.bundleIdentifier || hiddenBundleIDs.contains(id) {
            return true
        }
        func system(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            return path.hasPrefix("/System/Library/") || path.hasPrefix("/System/Applications/")
        }
        if let bundleURL = application.bundleURL {
            guard system(bundleURL), let bundle = Bundle(url: bundleURL) else { return false }
            return bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true
                || bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool == true
        }
        if let id { return id.hasPrefix("com.apple") }
        return application.executableURL.map(system) ?? false
    }

    private static let hiddenBundleIDs: Set<String> = [
        "com.apple.WindowManager", "com.apple.controlcenter", "com.apple.dock",
        "com.apple.notificationcenterui", "com.apple.LocalAuthentication.UIAgent",
        "com.apple.UserNotificationCenter", "com.apple.LocalAuthenticationRemoteService", "com.apple.SecurityAgent",
    ]

    func record(_ record:EventStreamRecord,classification:TimelineRecordClassification) {
        guard let app=classification.application else{return}
        let newSession=entries.first.map{$0.application.id != app.id && record.timestamp>$0.lastSeenAt} ?? false
        let index=entries.firstIndex{$0.application.id==app.id}
        var entry=index.map{entries[$0]} ?? .init(application:app,lastSession:.init(application:app,startedAt:record.timestamp,endedAt:nil),urlDomains:[],isExcluded:classification.suppressionReason == .applicationExcluded,lastSeenAt:record.timestamp)
        if newSession{entry.lastSession = .init(application:app,startedAt:record.timestamp,endedAt:nil)}
        entry.lastSession.endedAt=max(entry.lastSession.endedAt ?? .distantPast,record.timestamp)
        entry.lastSeenAt=max(entry.lastSeenAt,record.timestamp)
        if let host=classification.urlDomain,classification.suppressionReason == nil || classification.suppressionReason == .urlExcluded {
            entry.urlDomains.removeAll{$0.domain==host}
            entry.urlDomains.insert(.init(domain:host,isExcluded:classification.suppressionReason == .urlExcluded,lastSeenAt:record.timestamp),at:0)
        }
        if let index{entries[index]=entry}else{entries.insert(entry,at:0)}
        entries.sort{$0.lastSeenAt>$1.lastSeenAt}
    }
}

// Existing records are accepted
// while paused. Boundaries bypass the queue and classification. Recorder-level
// suppression bypasses classification; policy suppression still updates recents.
@MainActor final class TimelineRecordProcessor {
    private struct Pending {var record:EventStreamRecord;var suppressed:Bool}
    private var pending=[Pending]()
    private(set) var processingTask:Task<Void,Never>?
    var pendingCount:Int{pending.count}
    private let writer:()->TimelineSegmentWriter?
    private let classifier:TimelineRecordClassifier
    let recent:TimelineRecentApplicationStore
    private let onCompletedSegment:(EventStreamMetadata)->Void
    private let onError:(Error)->Void
    init(writer:@escaping ()->TimelineSegmentWriter?,classifier:TimelineRecordClassifier,recent:TimelineRecentApplicationStore,
         onCompletedSegment:@escaping (EventStreamMetadata)->Void,onError:@escaping (Error)->Void) {
        self.writer=writer;self.classifier=classifier;self.recent=recent;self.onCompletedSegment=onCompletedSegment;self.onError=onError
    }
    func receive(_ record:EventStreamRecord,isSuppressed:Bool=false) {
        guard writer() != nil else{return}
        if record.kind == .sessionStarted || record.kind == .sessionEnded{commit(record,isSuppressed:isSuppressed,classification:nil);return}
        pending.append(.init(record:record,suppressed:isSuppressed))
        if processingTask==nil{processingTask=Task{[weak self] in guard let self else{return};await self.process()}}
    }
    func cancelPendingRecords(){processingTask?.cancel();processingTask=nil;pending=[]}
    private func process()async {
        while !pending.isEmpty {
            guard !Task.isCancelled else{return}
            let item=pending.removeFirst()
            if item.suppressed{commit(item.record,isSuppressed:true,classification:nil)}
            else {
                let classification=await classifier.classify(item.record)
                guard !Task.isCancelled else{return}
                commit(item.record,isSuppressed:classification.suppressionReason != nil,classification:classification)
            }
        }
        processingTask=nil
    }
    private func commit(_ record:EventStreamRecord,isSuppressed:Bool,classification:TimelineRecordClassification?) {
        do {
            let completed=try isSuppressed ? writer()?.appendSuppressed(record):writer()?.append(record)
            if let completed{onCompletedSegment(completed)}
            if let classification{recent.record(record,classification:classification)}
        }catch{onError(error)}
    }
    deinit{processingTask?.cancel()}
}
