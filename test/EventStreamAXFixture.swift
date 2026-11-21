import AppKit
import Foundation

@main
struct EventStreamAXFixture {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x:100,y:100,width:620,height:440),
            styleMask:[.titled,.closable], backing:.buffered, defer:false)
        window.title = "Event stream static AX fixture"
        window.isReleasedWhenClosed = false
        let content = window.contentView!
        let label = NSTextField(labelWithString:"Fixture label")
        label.frame=NSRect(x:20,y:390,width:240,height:24)
        label.setAccessibilityIdentifier("static-label")
        content.addSubview(label)
        let field = NSTextField(frame:NSRect(x:20,y:350,width:280,height:28))
        field.stringValue="Fixture value"
        field.placeholderString="Fixture placeholder"
        field.setAccessibilityIdentifier("short-field")
        content.addSubview(field)
        let button = NSButton(title:"Fixture button", target:nil, action:nil)
        button.frame=NSRect(x:340,y:350,width:200,height:28)
        button.setAccessibilityIdentifier("fixture-button")
        content.addSubview(button)
        let secure = NSSecureTextField(frame:NSRect(x:20,y:305,width:280,height:28))
        secure.stringValue="synthetic-secret"
        secure.setAccessibilityIdentifier("secure-field")
        content.addSubview(secure)
        let scroll = NSScrollView(frame:NSRect(x:20,y:20,width:570,height:260))
        scroll.hasVerticalScroller=true
        let editor = NSTextView(frame:NSRect(x:0,y:0,width:550,height:1000))
        editor.string=String(repeating:"0123456789",count:180)
        editor.font=NSFont.monospacedSystemFont(ofSize:14,weight:.regular)
        editor.isVerticallyResizable=true
        editor.isHorizontallyResizable=false
        editor.textContainer?.containerSize=NSSize(width:550,height:CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView=true
        editor.setAccessibilityIdentifier("long-editor")
        scroll.documentView=editor
        content.addSubview(scroll)
        // This fixture stays behind other apps and never requests activation.
        window.orderBack(nil)
        app.finishLaunching()
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
            let ready:[String:Any] = ["pid":getpid(),"windowID":window.windowNumber,"visible":window.isVisible,"appHidden":app.isHidden,"windowCount":app.windows.count]
            let data=try! JSONSerialization.data(withJSONObject:ready,options:[.sortedKeys])
            FileHandle.standardOutput.write(data+Data([10]))
        }
        withExtendedLifetime(window) { app.run() }
    }
}
