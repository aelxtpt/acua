import ApplicationServices
import Foundation

@main
struct EventStreamAXNativeTests {
    @MainActor static var checks=0
    @MainActor static func check(_ name:String,_ value:@autoclosure()->Bool) {
        guard value() else { print("FAIL: \(name)"); exit(1) }
        checks += 1;print("PASS: \(name)")
    }
    @MainActor static func main() throws {
        guard CommandLine.arguments.count==2,let pid=Int32(CommandLine.arguments[1]), AXIsProcessTrusted() else {
            print("AX fixture PID and Accessibility permission required");exit(77)
        }
        let application=AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application,0.5)
        var failures:[String:Int32]=[:]
        func raw(_ node:AXUIElement,_ attribute:String)->CFTypeRef? {
            var result:CFTypeRef?
            let status=AXUIElementCopyAttributeValue(node,attribute as CFString,&result)
            guard status == .success else{failures[attribute]=status.rawValue;return nil}
            return result
        }
        var queue:[AXUIElement]=[application], index=0, found:[String:AXUIElement]=[:]
        var windows=0
        var nodeTypes:[[String:Any]]=[]
        for attempt in 0..<30 {
        queue=[application];index=0;found=[:];failures=[:];nodeTypes=[]
        while index<queue.count && index<100 {
            let node=queue[index];index += 1
            AXUIElementSetMessagingTimeout(node,0.5)
            if let identifier=raw(node,"AXIdentifier") as? String {found[identifier]=node}
            for attribute in ["AXChildren","AXWindows"] {
                if let values=raw(node,attribute) as? [AnyObject] {
                    if index==1 && attribute=="AXWindows" {windows=values.count}
                    for value in values {
                        if nodeTypes.count<12 {nodeTypes.append(["attribute":attribute,"typeID":CFGetTypeID(value),"AXTypeID":AXUIElementGetTypeID(),"swiftType":String(describing:type(of:value))])}
                        guard CFGetTypeID(value)==AXUIElementGetTypeID() else {continue}
                        let child=unsafeBitCast(value,to:AXUIElement.self)
                        if nodeTypes.count<12 {nodeTypes.append(["role":raw(child,"AXRole") as? String ?? "missing","equalsRoot":CFEqual(application,child)])}
                        if !queue.contains(where:{CFEqual($0,child)}) {queue.append(child)}
                    }
                }
            }
        }
        if ["static-label","short-field","fixture-button","secure-field","long-editor"].allSatisfy({found[$0] != nil}) {break}
        if attempt<29 {RunLoop.current.run(until:Date().addingTimeInterval(0.1))}
        }
        let identifiers=["static-label","short-field","fixture-button","secure-field","long-editor"]
        if !identifiers.allSatisfy({found[$0] != nil}) {
            let diagnostic:[String:Any] = ["found":Array(found.keys).sorted(),"visited":queue.count,"windows":windows,"errors":failures,"role":raw(application,"AXRole") as? String ?? "missing","nodes":nodeTypes]
            let data=try JSONSerialization.data(withJSONObject:diagnostic,options:[.sortedKeys])
            FileHandle.standardError.write(data+Data([10]))
        }
        check("real AX exposes all disposable fixture controls", identifiers.allSatisfy{found[$0] != nil})
        let button=EventStreamAXContext.describe(found["fixture-button"]!)
        check("native AX button role/title/identifier",button.role=="AXButton" && button.title=="Fixture button" && button.identifier=="fixture-button")
        let field=EventStreamAXContext.describe(found["short-field"]!)
        check("native AX field value and placeholder",field.role=="AXTextField" && field.value=="Fixture value" && field.placeholder=="Fixture placeholder")
        let label=EventStreamAXContext.describe(found["static-label"]!)
        check("native AX static text supplies label",label.role=="AXStaticText" && label.title=="Fixture label" && label.value=="Fixture label")
        let editor=EventStreamAXContext.describe(found["long-editor"]!)
        check("native long text emits the truncation marker",editor.role=="AXTextArea" && editor.value?.hasPrefix("[truncated to visible range] ")==true)
        let prefix="[truncated to visible range] "
        check("native visible text stays within requested UTF-16 budget",editor.value.map{($0 as NSString).length<=1000+prefix.utf16.count}==true)
        let secure=EventStreamAXContext.describe(found["secure-field"]!)
        check("native secure-field subrole is preserved",secure.subrole=="AXSecureTextField")
        check("native secure-field value does not expose synthetic secret",secure.value != "synthetic-secret" && secure.title != "synthetic-secret")
        // No full descriptions are logged: even this fixture's text is not
        // needed in result artifacts. This helper performs AX reads only.
        print("EVENT STREAM STATIC NATIVE AX: \(checks) checks passed")
    }
}
