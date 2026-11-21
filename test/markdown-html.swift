import Foundation

private struct Corpus:Decodable,Sendable {
    struct Sample:Decodable,Sendable{let name:String,text:String,html:String}
    let cases:[Sample]
}
private final class Failures:@unchecked Sendable {
    private let lock=NSLock();private var values=[String]()
    func append(_ value:String){lock.lock();values.append(value);lock.unlock()}
    var all:[String]{lock.lock();defer{lock.unlock()};return values}
}
private enum Cancelled:Error{case requested}

@main enum MarkdownHTMLTests {
    static func main() throws {
        let arguments=CommandLine.arguments
        let corpus=try JSONDecoder().decode(Corpus.self,from:Data(contentsOf:URL(fileURLWithPath:arguments[1])))
        precondition(corpus.cases.count==104)
        var rows=[[String:Any]]()
        for sample in corpus.cases {
            let actual=try MarkdownHTML.render(sample.text)
            let matched=actual.utf8.elementsEqual(sample.html.utf8)
            rows.append(["name":sample.name,"matched":matched])
            precondition(matched,"Markdown HTML mismatch: \(sample.name)")
            print("PASS Markdown HTML \(sample.name)")
        }
        let failures=Failures()
        DispatchQueue.concurrentPerform(iterations:8){worker in
            for index in stride(from:worker,to:corpus.cases.count,by:8) {
                let sample=corpus.cases[index]
                do{
                    let actual=try MarkdownHTML.render(sample.text)
                    if !actual.utf8.elementsEqual(sample.html.utf8){failures.append(sample.name)}
                }catch{failures.append("\(sample.name): \(error)")}
            }
        }
        precondition(failures.all.isEmpty,"Concurrent Markdown parsers differ: \(failures.all)")
        print("PASS Markdown parsers keep their output across concurrent requests")
        var cancelledBefore=false
        do{_ = try MarkdownHTML.render("text",checkpoint:{throw Cancelled.requested})}
        catch Cancelled.requested{cancelledBefore=true}
        precondition(cancelledBefore)
        print("PASS Markdown cancellation before parsing propagates")
        let unicodeBoundary=corpus.cases.first{$0.name=="chunk-boundary-utf8"}!.text
        for text in [String(repeating:"é **text**\n",count:30_000),unicodeBoundary] {
            var checkpoints=0,cancelledDuring=false
            do{
                _ = try MarkdownHTML.render(text,checkpoint:{
                    checkpoints += 1
                    if checkpoints==3{throw Cancelled.requested}
                })
            }catch Cancelled.requested{cancelledDuring=true}
            precondition(cancelledDuring && checkpoints==3)
        }
        // The cancellation must not poison the shared API or subsequent parser.
        let next=try MarkdownHTML.render("next")
        precondition(next=="<p>next</p>\n")
        print("PASS Markdown cancellation between input chunks cleans up and permits reuse")
        try JSONSerialization.data(withJSONObject:["cases":rows,"corpusCases":104,"localOperationalChecks":3,"concurrentWorkers":8,"allMatched":true,"userClipboardAccess":false,"nativeInput":false],options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:arguments[2]))
    }
}
