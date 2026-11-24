import AppKit

/// Isolated disposable app for real screenshot -> pointer-event verification.
@main
enum CoordinateFixture {
    final class PanelCanvas: NSView {
        override var isOpaque: Bool { true }
        override func draw(_ dirtyRect: NSRect) { NSColor.magenta.setFill(); bounds.fill() }
        override func mouseDown(with event: NSEvent) {
            CoordinateFixture.write(["event": "child-down", "window": event.windowNumber])
        }
        override func mouseDragged(with event: NSEvent) {
            CoordinateFixture.write(["event": "child-drag", "window": event.windowNumber])
        }
        override func mouseUp(with event: NSEvent) {
            CoordinateFixture.write(["event": "child-up", "window": event.windowNumber])
        }
        override func scrollWheel(with event: NSEvent) {
            CoordinateFixture.write(["event": "child-scroll", "window": event.windowNumber])
        }
    }
    final class SliderObserver: NSObject {
        @objc func didChange(_ sender: NSSlider) {
            CoordinateFixture.write(["event": "slider-change", "value": sender.doubleValue])
        }
    }
    static var directory: URL!
    static var monitor: Any?
    static func write(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10])
        let url = directory.appendingPathComponent("events.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let file = try! FileHandle(forWritingTo: url)
        try! file.seekToEnd(); try! file.write(contentsOf: data); try! file.close()
    }

    final class Canvas: NSView {
        let green = CGRect(x: 280, y: 65, width: 100, height: 55)
        let red = CGRect(x: 70, y: 140, width: 65, height: 55)
        let blue = CGRect(x: 430, y: 245, width: 65, height: 55)
        var dragging = false
        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.setFill(); bounds.fill()
            NSColor(calibratedRed: 0.05, green: 0.8, blue: 0.15, alpha: 1).setFill(); green.fill()
            NSColor(calibratedRed: 0.9, green: 0.08, blue: 0.08, alpha: 1).setFill(); red.fill()
            NSColor(calibratedRed: 0.05, green: 0.15, blue: 0.95, alpha: 1).setFill(); blue.fill()
        }
        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            dragging = red.contains(point)
            CoordinateFixture.write(["event": "down", "x": point.x, "y": point.y, "green": green.contains(point), "red": dragging])
        }
        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            CoordinateFixture.write(["event": "up", "drop": dragging && blue.contains(point), "x": point.x, "y": point.y])
            dragging = false
        }
        override func mouseDragged(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            CoordinateFixture.write(["event": "drag", "x": point.x, "y": point.y])
        }
        override func scrollWheel(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            CoordinateFixture.write(["event": "scroll", "green": green.contains(point)])
        }
    }

    static func main() throws {
        if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--display-info" {
            let primary = NSScreen.screens.first!.frame
            let displays = NSScreen.screens.map { screen -> [String: Any] in
                func rect(_ frame: CGRect) -> [String: CGFloat] { ["x": frame.minX, "y": primary.maxY - frame.maxY, "width": frame.width, "height": frame.height] }
                return ["id": (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber).uint32Value,
                    "bounds": rect(screen.frame), "workArea": rect(screen.visibleFrame), "scaleFactor": screen.backingScaleFactor]
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["displays": displays]), as: UTF8.self)); return
        }
        if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--transition-windows", let pid = Int32(CommandLine.arguments[2]) {
            let windows = (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []).filter {
                ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid &&
                ($0[kCGWindowName as String] as? String)?.hasPrefix("CUA Capture Transition ") == true
            }.map { ["id": $0[kCGWindowNumber as String]!, "bounds": $0[kCGWindowBounds as String]!, "layer": $0[kCGWindowLayer as String]!] }
            print(String(decoding: try JSONSerialization.data(withJSONObject: windows), as: UTF8.self)); return
        }
        if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--image-info" {
            let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))!
            var transparent = 0, partial = 0, opaque = 0
            for y in stride(from: 0, to: image.pixelsHigh, by: 3) {
                for x in stride(from: 0, to: image.pixelsWide, by: 3) {
                    guard let color = image.colorAt(x: x, y: y) else { continue }
                    if color.alphaComponent < 0.01 { transparent += 1 }
                    else if color.alphaComponent < 0.99 { partial += 1 }
                    else { opaque += 1 }
                }
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: ["width": image.pixelsWide, "height": image.pixelsHigh,
                "alpha": image.hasAlpha, "transparent": transparent, "partial": partial, "opaque": opaque]), as: UTF8.self)); return
        }
        if CommandLine.arguments.count > 2 && CommandLine.arguments[1] == "--locate-image" {
            let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))!
            var targets: [String: [Int]] = [:]
            for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: image.pixelsWide, by: 2) {
                    guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                    let key: String?
                    if y < 45 { key = nil } // Exclude the window's traffic-light controls.
                    // Captured JPEG profiles can lift the green channel of
                    // magenta. Require both dominant channels to beat green.
                    else if r > 0.65 && b > 0.65 && min(r, b) > g + 0.25 { key = "magenta" }
                    else if r > 0.65 && r > g + 0.25 && r > b + 0.25 { key = "red" }
                    else if g > 0.6 && g > r + 0.25 && g > b + 0.25 { key = "green" }
                    else if b > 0.65 && b > r + 0.25 && b > g + 0.25 { key = "blue" }
                    else { key = nil }
                    if let key {
                        let old = targets[key] ?? [x, y, x, y]
                        targets[key] = [min(x, old[0]), min(y, old[1]), max(x, old[2]), max(y, old[3])]
                    }
                }
            }
            var centers = targets.mapValues { [($0[0] + $0[2]) / 2, ($0[1] + $0[3]) / 2] }
            centers["__size"] = [image.pixelsWide, image.pixelsHigh]
            let data = try JSONSerialization.data(withJSONObject: centers, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let large = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 950, height: 650),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        large.title = "CUA large decoy"
        large.contentView = NSView(frame: large.contentView!.bounds)
        large.orderFront(nil)
        let small = NSWindow(contentRect: NSRect(x: 260, y: 240, width: 620, height: 360),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        small.title = "CUA coordinate target"
        let canvas = Canvas(frame: small.contentView!.bounds)
        small.contentView = canvas
        let sliderObserver = SliderObserver()
        let slider = NSSlider(value: 20, minValue: 0, maxValue: 100, target: sliderObserver, action: #selector(SliderObserver.didChange(_:)))
        slider.isContinuous = true
        slider.isHidden = true
        slider.frame = CGRect(x: 182, y: 315, width: 245, height: 28)
        slider.setAccessibilityLabel("CUA drag slider")
        canvas.addSubview(slider)
        let child = NSPanel(contentRect: NSRect(x: small.frame.minX + 35, y: small.frame.minY + 190, width: 95, height: 65),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        child.title = "CUA composition child"
        child.backgroundColor = .magenta; child.isOpaque = true
        child.contentView = PanelCanvas(frame: child.contentView!.bounds)
        child.hidesOnDeactivate = false
        small.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .scrollWheel]) { event in
            write(["event": "observed", "type": event.type.rawValue, "window": event.windowNumber,
                   "x": event.locationInWindow.x, "y": event.locationInWindow.y])
            return event
        }
        func screenCenter(_ rect: CGRect) -> [CGFloat] {
            let point = small.convertPoint(toScreen: canvas.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil))
            return [point.x, NSScreen.screens.first!.frame.maxY - point.y]
        }
        write(["event": "ready", "smallWindowID": small.windowNumber, "backingScale": small.backingScaleFactor,
               "redScreen": screenCenter(canvas.red), "blueScreen": screenCenter(canvas.blue)])
        _ = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let command = directory.appendingPathComponent("command")
            guard let value = try? String(contentsOf: command, encoding: .utf8) else { return }
            try? FileManager.default.removeItem(at: command)
            if value == "move" { small.setFrameOrigin(NSPoint(x: 340, y: 220)); write(["event": "moved"]) }
            if value == "restore" { small.setFrameOrigin(NSPoint(x: 260, y: 240)); small.makeKeyAndOrderFront(nil); write(["event": "restored"]) }
            if value == "focus-decoy" { large.makeKeyAndOrderFront(nil); write(["event": "decoy-focused"]) }
            if value == "slider-reset", let cell = slider.cell as? NSSliderCell {
                slider.isHidden = false
                slider.doubleValue = 20
                slider.layoutSubtreeIfNeeded()
                slider.display()
                let originKnob = cell.knobRect(flipped: slider.isFlipped)
                let travel = slider.bounds.width - originKnob.width
                let endKnob = originKnob.offsetBy(dx: 0.6 * travel, dy: 0)
                let primary = NSScreen.screens.first!.frame
                func point(_ knob: CGRect) -> [CGFloat] {
                    let location = slider.convert(CGPoint(x: knob.midX, y: knob.midY), to: nil)
                    let screen = small.convertPoint(toScreen: location)
                    return [screen.x, primary.maxY - screen.y]
                }
                write(["event": "slider-ready", "from": point(originKnob), "to": point(endKnob)])
            }
            if value == "slider-status" {
                write(["event": "slider-status", "value": slider.doubleValue])
                slider.isHidden = true
            }
            if value == "status" { write(["event": "status", "active": app.isActive, "keyWindow": app.keyWindow?.windowNumber ?? -1]) }
            if value == "show-child" {
                small.addChildWindow(child, ordered: .above); child.orderFront(nil)
                let center = [child.frame.midX, NSScreen.screens.first!.frame.maxY - child.frame.midY]
                write(["event": "child-shown", "windowID": child.windowNumber, "centerScreen": center])
            }
            if value == "hide-child" {
                child.orderOut(nil); small.removeChildWindow(child)
                write(["event": "child-hidden"])
            }
            if value == "move-to-other-display" {
                // Any display other than the primary one (the menu bar's), so
                // its global coordinates, origin and scale differ from it.
                let primary = NSScreen.screens.first!
                guard let other = NSScreen.screens.dropFirst().first else {
                    write(["event": "no-other-display"])
                    return
                }

                let visible = other.visibleFrame
                small.setFrameOrigin(NSPoint(x: visible.midX - small.frame.width / 2, y: visible.midY - small.frame.height / 2))
                small.makeKeyAndOrderFront(nil)
                // The window's backing scale follows its new screen once the
                // move is processed, so report on the next run-loop turn.
                DispatchQueue.main.async {
                    let otherNumber = other.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! NSNumber
                    write(["event": "moved-to-other-display", "displayID": otherNumber.uint32Value,
                           "onOtherDisplay": small.screen == other, "backingScale": small.backingScaleFactor,
                           "primaryScale": primary.backingScaleFactor,
                           "displayFrame": [other.frame.minX, primary.frame.maxY - other.frame.maxY, other.frame.width, other.frame.height],
                           "redScreen": screenCenter(canvas.red), "greenScreen": screenCenter(canvas.green),
                           "blueScreen": screenCenter(canvas.blue)])
                }
            }
            if value == "window-server-frame" {
                // WindowServer applies a move across displays after AppKit
                // reports it; captures read this frame, not the AppKit one.
                let info = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(small.windowNumber)) as? [[String: Any]])?.first
                let bounds = (info?[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
                write(["event": "window-server-frame",
                       "frame": bounds.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []])
            }
            if value == "close" { small.orderOut(nil); write(["event": "closed"]) }
            if value == "quit" { app.terminate(nil) }
        }
        withExtendedLifetime(sliderObserver) { app.run() }
    }
}
