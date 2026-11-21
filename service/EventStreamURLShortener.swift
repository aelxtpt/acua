import Foundation

struct EventStreamURLShortener {
    struct Configuration:Equatable {
        var individualLimit:Int?
        var totalLimit:Int?
        var includeQuery:Bool
        var includeFragment:Bool
        // baseHost is accepted but not stored.
        init(individualLimit:Int?,totalLimit:Int?,includeQuery:Bool,includeFragment:Bool,baseHost:String?=nil) {
            self.individualLimit=individualLimit;self.totalLimit=totalLimit
            self.includeQuery=includeQuery;self.includeFragment=includeFragment
        }
    }
    var configuration:Configuration
    private(set) var accumulated=0
    private(set) var domains:[String:Int]=[:]
    private(set) var urls:Set<URL>=[]
    init(configuration:Configuration) {self.configuration=configuration}

    // Insert every URL, including rejected/image URLs, before
    // evaluating it. Repeated URLs still consume budget and domain counts.
    mutating func trim(url:URL,isImage:Bool) -> String? {
        urls.insert(url)
        var count=accumulated
        let evaluated=evaluate(url,isImage:isImage,accumulated:&count)
        accumulated=count
        guard let result=evaluated else {return nil}
        if let host=result.host {domains[host,default:0] += 1}
        return result.text
    }
    private func evaluate(_ url:URL,isImage:Bool,accumulated:inout Int) -> (host:String?,text:String)? {
        guard let scheme=url.scheme,!["webdoc","data"].contains(scheme.lowercased()),!isImage else {return nil}
        // File URLs bypass normalization, limits and accumulated/domain counts.
        if url.isFileURL {return (nil,url.absoluteString)}
        guard var components=URLComponents(url:url,resolvingAgainstBaseURL:false) else {return nil}
        if components.scheme=="https" || components.scheme=="http" {components.scheme=nil}
        var host=components.host
        if let original=host {
            if original.hasPrefix("www.") {host=String(original.dropFirst(4))}
            components.host=host
        }
        guard components.string != nil else {return nil}
        if !configuration.includeQuery {components.query=nil}
        if !configuration.includeFragment {components.fragment=nil}
        guard var text=components.string else {return nil}
        if text.hasPrefix("//") {text=String(text.dropFirst(2))}
        if let limit=configuration.individualLimit {
            // Preserve native checked arithmetic / String range preconditions,
            // including its internal invalid-limit traps rather than clamping.
            if text.index(text.startIndex,offsetBy:limit+1,limitedBy:text.endIndex) != nil {
                text=String(text.prefix(limit-1))+"…"
            }
        }
        let count=text.count
        if let limit=configuration.totalLimit,accumulated+count>limit {
            accumulated += 1
            return (host,"…")
        }
        accumulated += count
        return (host,text)
    }
    // Estimate unique URLs with fresh accounting and isImage=false.
    // It changes configuration, not accumulated/domain/URL capture state.
    mutating func compactConfigurationIfNeeded() -> Int {
        if configuration.totalLimit==nil {configuration.totalLimit=4000}
        while true {
            var estimate=0
            for url in urls {_ = evaluate(url,isImage:false,accumulated:&estimate)}
            if estimate <= configuration.totalLimit! || !makeMoreCompact() {return estimate}
        }
    }
    private mutating func makeMoreCompact() -> Bool {
        if configuration.includeFragment {configuration.includeFragment=false;return true}
        if configuration.includeQuery {configuration.includeQuery=false;return true}
        for limit in stride(from:120,through:20,by:-10) {
            if configuration.individualLimit==nil || limit<configuration.individualLimit! {
                configuration.individualLimit=limit;return true
            }
        }
        return false
    }
    mutating func reset() {accumulated=0;domains.removeAll();urls.removeAll()}
}
