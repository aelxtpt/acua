import AppKit

struct EventStreamRecordingWarningState {
    private var dismissedURLs = Set<String>()
    private var context: EventStreamBlockedCaptureContext?

    var visibleContext: EventStreamBlockedCaptureContext? {
        guard let context, !dismissedURLs.contains(context.id) else { return nil }
        return context
    }

    mutating func update(_ context: EventStreamBlockedCaptureContext?) {
        self.context = context
    }

    mutating func dismiss() {
        if let context { dismissedURLs.insert(context.id) }
    }

    static func siteName(for url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

@MainActor final class EventStreamRecordingWarningPopover {
    private var state = EventStreamRecordingWarningState()
    private var popover: NSPopover?
    private var presentedContext: EventStreamBlockedCaptureContext?

    func reset() {
        state = EventStreamRecordingWarningState()
        close()
    }

    func update(_ context: EventStreamBlockedCaptureContext?, anchor: NSView?) {
        state.update(context)
        guard let context = state.visibleContext, let anchor, anchor.window != nil else {
            close()
            return
        }
        if presentedContext == context, popover?.isShown == true { return }

        let popover = self.popover ?? NSPopover()
        self.popover = popover
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentSize = NSSize(width: 330, height: 76)
        presentedContext = context
        let content = EventStreamRecordingWarningViewController(context: context)
        content.onDismiss = { [weak self, weak content, weak popover] in
            guard let self, let content, let popover, self.popover === popover,
                  popover.contentViewController === content else { return }
            dismiss()
        }
        popover.contentViewController = content
        if !popover.isShown {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    @discardableResult
    func dismissIfShown() -> Bool {
        guard popover?.isShown == true else { return false }
        dismiss()
        return true
    }

    private func dismiss() {
        state.dismiss()
        close()
    }

    private func close() {
        let closing = popover
        popover = nil
        presentedContext = nil
        closing?.performClose(nil)
    }
}

@MainActor private final class EventStreamRecordingWarningViewController: NSViewController {
    private let context: EventStreamBlockedCaptureContext
    private var windowKeyObserver: NSObjectProtocol?
    var onDismiss: (() -> Void)?

    init(context: EventStreamBlockedCaptureContext) {
        self.context = context
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 330, height: 76))
        root.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(dismissWarning)))
        let app = context.application
        let appURL = app.bundleURL ?? app.bundleIdentifier.flatMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
        let icon = NSImageView()
        icon.image = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let site = EventStreamRecordingWarningState.siteName(for: context.normalizedURL)
        let title = NSTextField(labelWithString: "Recording Disallowed on \(site)")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        let details = NSTextField(wrappingLabelWithString: "Actions on \(site) will be excluded from the recording.")
        details.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        details.textColor = .secondaryLabelColor
        details.maximumNumberOfLines = 3
        for label in [title, details] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let labels = NSStackView(views: [title, details])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(icon)
        root.addSubview(labels)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 40),
            icon.heightAnchor.constraint(equalToConstant: 40),
            labels.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            labels.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            details.widthAnchor.constraint(equalTo: labels.widthAnchor),
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard windowKeyObserver == nil, let window = view.window else { return }
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissWarning() }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let windowKeyObserver { NotificationCenter.default.removeObserver(windowKeyObserver) }
        windowKeyObserver = nil
    }

    @objc private func dismissWarning() { onDismiss?() }
}
