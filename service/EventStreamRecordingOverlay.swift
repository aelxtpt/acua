import AppKit

@MainActor final class EventStreamRecordingOverlay: NSObject, NSWindowDelegate {
    private static let size = NSSize(width: 155, height: 56)
    private let panel = RecordingOverlayPanel()
    private let clock = NSTextField(labelWithString: "")
    private let now: () -> Date
    private var startedAt: Date?
    private var timer: Timer?
    private var wasDragged = false

    init(now: @escaping () -> Date = Date.init, onStop: @escaping () -> Void, onDiscard: @escaping () -> Void) {
        self.now = now
        super.init()
        panel.delegate = self
        panel.contentView = makeContent(onStop: onStop, onDiscard: onDiscard)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func show(startedAt: Date) {
        self.startedAt = startedAt
        tick()
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    if let self { self.tick() }
                    else { timer.invalidate() }
                }
            }
            timer.tolerance = 0.1
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        if !panel.isVisible {
            wasDragged = false
            let location = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(location) })
                ?? NSScreen.main {
                panel.setFrameOrigin(Self.origin(in: screen.visibleFrame))
            }
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        startedAt = nil
        panel.orderOut(nil)
    }

    static func elapsedText(startedAt: Date, now: Date) -> String {
        let interval = now.timeIntervalSince(startedAt)
        let seconds = Int64(exactly: max(0, interval).rounded(.towardZero)) ?? 0
        return Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }

    static func origin(in visible: NSRect, preserving prior: NSPoint? = nil) -> NSPoint {
        let ideal = prior ?? NSPoint(x: visible.midX - size.width / 2, y: visible.minY + 93)
        return NSPoint(x: min(max(ideal.x, visible.minX), visible.maxX - size.width),
                       y: min(max(ideal.y, visible.minY), visible.maxY - size.height))
    }

    func windowWillMove(_ notification: Notification) {
        wasDragged = true
    }

    @objc private func screenChanged() {
        guard panel.isVisible, !NSScreen.screens.isEmpty else { return }
        func overlap(_ screen: NSScreen) -> CGFloat {
            let intersection = screen.visibleFrame.intersection(panel.frame)
            return intersection.isNull ? 0 : intersection.width * intersection.height
        }
        let closest = NSScreen.screens.max { overlap($0) < overlap($1) }
        let screen = closest.flatMap { overlap($0) > 0 ? $0 : nil } ?? NSScreen.main ?? NSScreen.screens.first
        if let screen {
            panel.setFrameOrigin(Self.origin(in: screen.visibleFrame, preserving: wasDragged ? panel.frame.origin : nil))
        }
    }

    private func tick() {
        if let startedAt { clock.stringValue = Self.elapsedText(startedAt: startedAt, now: now()) }
    }

    private func makeContent(onStop: @escaping () -> Void, onDiscard: @escaping () -> Void) -> NSView {
        let content = NSView(frame: NSRect(origin: .zero, size: Self.size))
        let shell = NSView(frame: NSRect(x: 5, y: 3, width: 145, height: 46))
        shell.wantsLayer = true
        shell.layer?.shadowColor = NSColor.black.cgColor
        shell.layer?.shadowOpacity = 0.12
        shell.layer?.shadowRadius = 4
        shell.layer?.shadowOffset = CGSize(width: 0, height: -2)
        shell.layer?.shadowPath = CGPath(roundedRect: shell.bounds, cornerWidth: 16, cornerHeight: 16, transform: nil)
        content.addSubview(shell)

        let background = NSView(frame: shell.bounds)
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor
        background.layer?.cornerRadius = 16
        background.layer?.cornerCurve = .continuous
        shell.addSubview(background)

        let controls = NSView(frame: shell.bounds.insetBy(dx: 2, dy: 2))
        controls.wantsLayer = true
        controls.layer?.cornerRadius = 14
        controls.layer?.cornerCurve = .continuous
        controls.layer?.masksToBounds = true
        shell.addSubview(controls)

        let stop = RecordingOverlayButton(frame: NSRect(x: 0, y: 0, width: 74, height: 42),
                                          title: "Stop Recording", onClick: onStop)
        stop.addSubview(symbol("stop.circle", color: .systemRed, frame: NSRect(x: 8, y: 11, width: 22, height: 20)))
        clock.frame = NSRect(x: 35, y: 14, width: 36, height: 14)
        clock.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        clock.textColor = .systemRed
        clock.setAccessibilityElement(false)
        stop.addSubview(clock)
        controls.addSubview(stop)

        let discard = RecordingOverlayButton(frame: NSRect(x: 75, y: 0, width: 42, height: 42),
                                             title: "Discard Recording", onClick: onDiscard)
        discard.addSubview(symbol("trash", color: .white, frame: NSRect(x: 10, y: 10, width: 22, height: 22)))
        controls.addSubview(discard)
        for x in [74.0, 117.0] {
            let separator = NSView(frame: NSRect(x: x, y: 0, width: 1, height: 42))
            separator.wantsLayer = true
            separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
            controls.addSubview(separator)
        }
        let handle = RecordingOverlayDragHandle(frame: NSRect(x: 118, y: 0, width: 23, height: 42))
        handle.wantsLayer = true
        handle.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        handle.setAccessibilityElement(true)
        handle.setAccessibilityRole(.handle)
        handle.setAccessibilityLabel("Move Record & Replay recording controls")
        controls.addSubview(handle)

        let border = RecordingOverlayDecoration(frame: shell.bounds.insetBy(dx: 1, dy: 1))
        border.wantsLayer = true
        border.layer?.cornerRadius = 15
        border.layer?.cornerCurve = .continuous
        border.layer?.borderWidth = 1
        border.layer?.borderColor = NSColor.white.withAlphaComponent(0.05).cgColor
        shell.addSubview(border)
        return content
    }

    private func symbol(_ name: String, color: NSColor, frame: NSRect) -> NSImageView {
        let view = NSImageView(frame: frame)
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        view.imageScaling = .scaleNone
        view.contentTintColor = color
        return view
    }
}

@MainActor private final class RecordingOverlayPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 155, height: 56),
                   styleMask: [.nonactivatingPanel], backing: .buffered, defer: false)
        title = "Record & Replay Recording Controls"
        isReleasedWhenClosed = false
        isFloatingPanel = true
        level = .floating
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        worksWhenModal = true
        isMovableByWindowBackground = false
        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { nil }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor private final class RecordingOverlayButton: NSButton {
    private let onClick: () -> Void

    init(frame: NSRect, title: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: frame)
        self.title = ""
        isBordered = false
        focusRingType = .none
        toolTip = title
        setAccessibilityLabel(title)
        target = self
        action = #selector(clicked)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }
    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        layer?.backgroundColor = flag ? NSColor.white.withAlphaComponent(0.05).cgColor : nil
    }
    @objc private func clicked() { onClick() }
}

@MainActor private final class RecordingOverlayDecoration: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class RecordingOverlayDragHandle: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.32).setFill()
        for offset in [-4.0, 0.0, 4.0] {
            NSBezierPath(rect: NSRect(x: bounds.midX - 3.5, y: bounds.midY - 0.5 + offset, width: 7, height: 1)).fill()
        }
    }
}
