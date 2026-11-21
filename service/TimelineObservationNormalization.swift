import Foundation

enum TimelineError:Error,CustomStringConvertible {
    case invalidApplicationRule
    case invalidURLRule
    case recorderStopped
    var description:String {
        switch self {
        case .recorderStopped:return "Computer History is stopped. Enable Computer History first."
        case .invalidApplicationRule:return "Computer History app observation rules require only a non-empty bundleID."
        case .invalidURLRule:return "Computer History URL observation rules require only a valid urlDomain."
        }
    }
}
extension TimelineObservationSettings {
    // Validate each list, preserving first occurrence order, then
    // remove allow rules that also occur in the normalized block list.
    func normalized()throws->Self {
        func rules(_ input:[TimelineObservationRule])throws->[TimelineObservationRule] {
            var result=[TimelineObservationRule](),seen=Set<TimelineObservationRule>()
            for var rule in input {
                switch rule.scope {
                case .app:
                    guard let bundle=rule.bundleID,!bundle.isEmpty,rule.urlDomain==nil else{throw TimelineError.invalidApplicationRule}
                case .url:
                    guard let domain=rule.urlDomain?.lowercased(),!domain.isEmpty,rule.bundleID==nil else{throw TimelineError.invalidURLRule}
                    rule.urlDomain=domain
                }
                if seen.insert(rule).inserted{result.append(rule)}
            }
            return result
        }
        let allow=try rules(allowlist),block=try rules(blocklist),blocked=Set(block)
        return .init(defaultApplicationBehavior:defaultApplicationBehavior,defaultURLBehavior:defaultURLBehavior,
            allowlist:allow.filter{!blocked.contains($0)},blocklist:block)
    }
}
