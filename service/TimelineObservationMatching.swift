import Foundation
extension TimelineObservationRule {
    func matchesApplication(bundleIdentifier:String?)->Bool {
        scope == .app && bundleID == bundleIdentifier
    }
    func matches(host:String)->Bool {
        guard scope == .url,let urlDomain else{return false}
        let hostParts=host.lowercased().split(separator:"."),domainParts=urlDomain.lowercased().split(separator:".")
        return hostParts.count>=domainParts.count && hostParts.suffix(domainParts.count).elementsEqual(domainParts)
    }
    func matches(url:String?)->Bool {
        guard let url,let host=URLComponents(string:url)?.host else{return false}
        return matches(host:host)
    }
}
