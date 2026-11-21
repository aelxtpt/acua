import Foundation

@main enum URLShortenerTests {
    typealias Shortener=EventStreamURLShortener
    static var checks=0
    static func check(_ label:String,_ condition:@autoclosure ()->Bool) {
        let okay=condition();if !okay {fputs("FAIL: \(label)\n",stderr)}
        precondition(okay,label);checks += 1;print("PASS: \(label)")
    }
    static func make(_ individual:Int?=nil,_ total:Int?=nil,query:Bool=true,fragment:Bool=true,baseHost:String?=nil)->Shortener {
        .init(configuration:.init(individualLimit:individual,totalLimit:total,includeQuery:query,includeFragment:fragment,baseHost:baseHost))
    }
    static func url(_ s:String)->URL {URL(string:s)!}
    static func main() {
        setbuf(stdout,nil)
        let source=url("https://www.example.com/path?q=1#section"),expected="example.com/path?q=1#section"
        var s=make()
        check("https and leading www are removed from display",s.trim(url:source,isImage:false)==expected)
        check("first display updates accumulated characters and normalized domain",s.accumulated==expected.count && s.domains==["example.com":1] && s.urls==[source])
        check("duplicate URL still renders and consumes budget",s.trim(url:source,isImage:false)==expected && s.accumulated==expected.count*2 && s.domains==["example.com":2] && s.urls.count==1)
        let saved=s.configuration;s.reset()
        check("reset clears capture state and retains configuration",s.accumulated==0 && s.domains.isEmpty && s.urls.isEmpty && s.configuration==saved)
        s=make(query:false,fragment:true)
        check("query can be removed while fragment is retained",s.trim(url:source,isImage:false)=="example.com/path#section")
        s=make(query:true,fragment:false)
        check("fragment can be removed while query is retained",s.trim(url:source,isImage:false)=="example.com/path?q=1")
        s=make(query:false,fragment:false)
        check("query and fragment can both be removed",s.trim(url:source,isImage:false)=="example.com/path")
        s=make(baseHost:"example.com")
        check("baseHost input is ignored by the trimming configuration",s.trim(url:source,isImage:false)==expected)
        s=make()
        check("www prefix is removed once",s.trim(url:url("http://www.www.example.com/a"),isImage:false)=="www.example.com/a")
        check("other schemes and ports are retained",s.trim(url:url("ftp://www.example.com:21/a"),isImage:false)=="ftp://example.com:21/a")
        check("userinfo is retained with scheme-less web display",s.trim(url:url("https://user:pass@www.example.com:443/a"),isImage:false)=="user:pass@example.com:443/a")
        check("mailto without host remains displayable",s.trim(url:url("mailto:person@example.com"),isImage:false)=="mailto:person@example.com")
        check("uppercase schemes and www prefixes are not stripped",s.trim(url:url("HTTP://WWW.Example.com/a"),isImage:false)=="HTTP://WWW.Example.com/a")
        let before=s.accumulated,domains=s.domains
        let relative=url("relative/path"),data=url("DaTa:text/plain,body"),webdoc=url("WEBDOC://example.com/path"),image=url("https://images.example/a.png")
        check("relative URLs without scheme are filtered",s.trim(url:relative,isImage:false)==nil)
        check("data scheme filter is case insensitive",s.trim(url:data,isImage:false)==nil)
        check("webdoc scheme filter is case insensitive",s.trim(url:webdoc,isImage:false)==nil)
        check("image display is filtered",s.trim(url:image,isImage:true)==nil)
        check("filtered URLs enter unique set without changing counters",s.urls.isSuperset(of:[relative,data,webdoc,image]) && s.accumulated==before && s.domains==domains)
        s=make(1,0,query:false,fragment:false)
        let file=URL(fileURLWithPath:"/tmp/a long file.txt")
        check("file URLs bypass all limits and preserve absolute URL",s.trim(url:file,isImage:false)==file.absoluteString && s.accumulated==0 && s.domains.isEmpty && s.urls==[file])
        check("image flag also filters file URL",s.trim(url:file,isImage:true)==nil && s.accumulated==0)
        s=make(3)
        check("individual exact boundary is retained",s.trim(url:url("http://abc"),isImage:false)=="abc")
        check("individual over-limit uses prefix limit-minus-one plus ellipsis",s.trim(url:url("http://abcd"),isImage:false)=="ab…")
        s=make(1)
        check("individual limit one produces only ellipsis",s.trim(url:url("http://ab"),isImage:false)=="…")
        s=make(0)
        check("zero individual limit retains valid empty display",s.trim(url:url("http:"),isImage:false)=="" && s.accumulated==0)
        s=make(4)
        check("truncation counts displayed percent-encoded characters",s.trim(url:url("https://a/😀"),isImage:false)=="a/%…")
        s=make(nil,3)
        check("total limit exact boundary is included",s.trim(url:url("http://ab"),isImage:false)=="ab" && s.trim(url:url("http://c"),isImage:false)=="c" && s.accumulated==3)
        check("over-budget total emits ellipsis and counts one",s.trim(url:url("http://d"),isImage:false)=="…" && s.accumulated==4 && s.domains["d"]==1)
        check("further over-budget calls keep consuming one",s.trim(url:url("http://e"),isImage:false)=="…" && s.accumulated==5)
        s=make(nil,0)
        check("zero total limit emits ellipsis rather than nil",s.trim(url:source,isImage:false)=="…" && s.accumulated==1)
        s=make()
        check("compaction assigns missing total limit to4000 even when empty",s.compactConfigurationIfNeeded()==0 && s.configuration.totalLimit==4000 && s.configuration.individualLimit==nil)
        s=make(nil,20)
        let repeated=url("http://example")
        for _ in 0..<10 {_ = s.trim(url:repeated,isImage:false)}
        let actual=s.accumulated,actualDomains=s.domains
        check("compaction estimates each unique URL once",s.compactConfigurationIfNeeded()==7 && s.urls.count==1 && s.accumulated==actual && s.domains==actualDomains && s.configuration.includeQuery && s.configuration.includeFragment)
        s=make(nil,3)
        for index in 0..<6 {_ = s.trim(url:url("https://example.com/path\(index)?q=long#fragment"),isImage:false)}
        let totalBefore=s.accumulated,domainsBefore=s.domains,urlsBefore=s.urls
        let estimate=s.compactConfigurationIfNeeded()
        check("exhausted compaction drops fragment/query and lowers individual limit to20",estimate==6 && !s.configuration.includeQuery && !s.configuration.includeFragment && s.configuration.individualLimit==20)
        check("compaction preserves actual capture accounting and seen URLs",s.accumulated==totalBefore && s.domains==domainsBefore && s.urls==urlsBefore)
        s=make(19,0,query:false,fragment:false)
        _ = s.trim(url:source,isImage:false)
        check("compaction does not raise an existing limit below20",s.compactConfigurationIfNeeded()==1 && s.configuration.individualLimit==19)
        s=make(nil,3)
        for index in 0..<6 {_ = s.trim(url:url("https://images.example/path\(index).png"),isImage:true)}
        check("compaction re-evaluates seen image URLs as nonimages",s.accumulated==0 && s.domains.isEmpty && s.compactConfigurationIfNeeded()==6 && s.configuration.individualLimit==20)
        let config=s.configuration;s.reset()
        check("reset retains compacted configuration",s.configuration==config && s.urls.isEmpty && s.accumulated==0)
        s=make();_ = s.trim(url:source,isImage:false);var copy=s
        _ = copy.trim(url:url("http://other.example/path"),isImage:false)
        check("copied shorteners have independent accounting",copy.urls.count==2 && s.urls.count==1 && s.domains["other.example"]==nil)
        let relativeWithBase=URL(string:"child?q=1",relativeTo:url("https://example.com/base/"))!
        s=make()
        check("relative URL with base is not resolved by URLComponents",s.trim(url:relativeWithBase,isImage:false)=="child?q=1" && s.domains.isEmpty)
        print("Event-stream URL shortener: \(checks) checks passed")
    }
}
