import AppKit
import WebKit

@main
enum WebFormFixture {
    static var directory: URL!
    static var web: WKWebView!
    static var window: NSWindow!
    static var decoy: NSTextView!
    static var other: NSWindow!
    static let controller = Controller()

    static func write(_ value: [String: Any]) {
        let file = directory.appendingPathComponent("events.jsonl")
        let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        let handle = try! FileHandle(forWritingTo: file)
        try! handle.seekToEnd(); try! handle.write(contentsOf: data); try! handle.close()
    }

    final class Controller: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard var value = message.body as? [String: Any] else { return }
            value["event"] = "dom"; write(value)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            write(["event": "ready", "window": window.windowNumber, "pid": getpid()])
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            write(["event": "web-process-terminated"])
        }
    }

    static let html = #"""
    <!doctype html><html><head><meta charset="utf-8"><title>Owned browser form</title>
    <style>body{font:18px system-ui;margin:24px}label{display:block;margin:16px 0 6px}input,textarea,button{font:18px system-ui}input[type=text],textarea{width:560px}textarea{height:80px}input[type=range]{width:500px}button{margin:12px 12px 0 0}</style></head>
    <body><h1>Owned browser form</h1><form id="form">
    <label for="name">Owned name field</label><input id="name" aria-label="Owned name field" type="text" value="untouched">
    <label for="notes">Owned notes field</label><textarea id="notes" aria-label="Owned notes field">🙂 início café / primeiro alvo / segundo alvo fim 👩🏽‍💻</textarea>
    <label for="level">Owned level slider</label><input id="level" aria-label="Owned level slider" type="range" min="0" max="100" value="20">
    <div><button id="submit" type="submit">Submit owned form</button><button id="disabled" type="button" disabled>Disabled owned button</button></div>
    <output id="result" aria-live="polite">Not submitted</output></form>
    <script>
    let submissions=0;
    function emit(e){window.webkit.messageHandlers.fixture.postMessage({kind:e.type,target:e.target.id,trusted:e.isTrusted,value:e.target.value||'',x:e.clientX||0,y:e.clientY||0});}
    for(const kind of ['input','change','click','pointerdown','pointermove','pointerup']) document.addEventListener(kind,emit);
    document.getElementById('form').addEventListener('submit',e=>{e.preventDefault();++submissions;document.getElementById('result').textContent='Submitted '+submissions;emit(e);});
    window.fixtureState=()=>({name:document.getElementById('name').value,nameSelection:[document.getElementById('name').selectionStart,document.getElementById('name').selectionEnd],notes:document.getElementById('notes').value,selection:[document.getElementById('notes').selectionStart,document.getElementById('notes').selectionEnd],level:Number(document.getElementById('level').value),submissions,active:document.activeElement.id,sliderRect:(()=>{const r=document.getElementById('level').getBoundingClientRect();return [r.x,r.y,r.width,r.height]})()});
    </script></body></html>
    """#

    static func main() {
        directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let menu = NSMenu(); let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        app.mainMenu = menu
        let config = WKWebViewConfiguration()
        config.userContentController.add(controller, name: "fixture")
        window = NSWindow(contentRect: CGRect(x: 220, y: 120, width: 720, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "CUA owned WebKit form"
        web = WKWebView(frame: window.contentView!.bounds, configuration: config)
        web.autoresizingMask = [.width, .height]; web.navigationDelegate = controller
        window.contentView!.addSubview(web)
        other = NSWindow(contentRect: CGRect(x: 50, y: 100, width: 340, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        other.title = "CUA browser decoy"
        decoy = NSTextView(frame: CGRect(x: 10, y: 10, width: 320, height: 180)); decoy.string = "DO NOT TOUCH WEB DECOY"
        other.contentView!.addSubview(decoy); other.orderFront(nil)
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(web); app.activate(ignoringOtherApps: true)
        web.loadHTMLString(html, baseURL: URL(string: "about:blank"))
        _ = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { _ in
            let file = directory.appendingPathComponent("command")
            guard let command = try? String(contentsOf: file, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: file)
            if command == "state" {
                web.evaluateJavaScript("window.fixtureState()") { result, error in
                    guard var state = result as? [String: Any] else { write(["event": "state-error", "error": String(describing: error)]); return }
                    state["event"] = "state"; state["decoy"] = decoy.string
                    state["keyWindow"] = app.keyWindow?.windowNumber ?? -1
                    if let records = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(window.windowNumber)) as? [[String: Any]],
                       let bounds = records.first?[kCGWindowBounds as String] { state["windowBounds"] = bounds }
                    if let rect = state["sliderRect"] as? [Double], rect.count == 4 {
                        let centerY = rect[1] + rect[3] / 2
                        let point = web.convert(CGPoint(x: rect[0], y: web.isFlipped ? centerY : web.bounds.height - centerY), to: nil)
                        let screen = window.convertPoint(toScreen: point)
                        state["sliderScreen"] = [screen.x, (NSScreen.screens.first?.frame.maxY ?? 0) - screen.y - rect[3] / 2, rect[2], rect[3]]
                        state["webViewFlipped"] = web.isFlipped
                    }
                    write(state)
                }
            } else if command == "focus-decoy" {
                other.makeKeyAndOrderFront(nil); other.makeFirstResponder(decoy)
                write(["event": "decoy-focused"])
            } else if command == "focus-main" {
                window.makeKeyAndOrderFront(nil); window.makeFirstResponder(web)
                write(["event": "main-focused"])
            }
        }
        app.run()
    }
}
