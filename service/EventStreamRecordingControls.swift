import AppKit

@MainActor final class EventStreamRecordingControls: NSObject {
    private let onRecordingEnded: (String, Bool) -> Void
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private let statusView = EventStreamRecordingStatusView()
    private var overlay: EventStreamRecordingOverlay?
    private let warning = EventStreamRecordingWarningPopover()

    init(onRecordingEnded: @escaping (String, Bool) -> Void) {
        self.onRecordingEnded = onRecordingEnded
    }

    func refresh() {
        let recording = EventStreamRecordingOwner.activeRecordingStatus
        let active = recording != nil
        if active, statusItem == nil { statusItem = makeStatusItem() }
        statusItem?.isVisible = active
        if active { refreshApplications() }
        else {
            statusMenu?.cancelTracking()
            statusView.isPressed = false
        }
        if let startedAt = recording?.startedAt {
            let overlay = self.overlay ?? EventStreamRecordingOverlay(
                onStop: { [weak self] in self?.stopClicked() },
                onDiscard: { [weak self] in self?.discardClicked() }
            )
            self.overlay = overlay
            overlay.show(startedAt: startedAt)
        } else {
            overlay?.hide()
        }
        warning.reset()
        refreshWarning()
    }

    func refreshWarning() {
        warning.update(EventStreamRecordingOwner.activeBlockedContext, anchor: statusItem?.button)
    }

    func refreshApplications() {
        guard let statusItem, statusItem.isVisible else { return }
        statusItem.length = statusView.update(applications: EventStreamRecordingOwner.observedApplications)
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let title = "Record & Replay is recording your actions"
        if let button = item.button {
            button.toolTip = title
            button.setAccessibilityLabel(title)
            button.setAccessibilityHelp("Open Record & Replay recording controls")
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: .leftMouseDown)
            statusView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(statusView)
            NSLayoutConstraint.activate([
                statusView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                statusView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                statusView.topAnchor.constraint(equalTo: button.topAnchor, constant: -2),
                statusView.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: 2),
            ])
        }

        let menu = NSMenu()
        let stop = menu.addItem(withTitle: "Stop Recording", action: #selector(stopClicked), keyEquivalent: "")
        stop.target = self
        stop.image = EventStreamRecordingStatusView.symbol("stop.circle", pointSize: 17)
        let discard = menu.addItem(withTitle: "Discard Recording", action: #selector(discardClicked), keyEquivalent: "")
        discard.target = self
        discard.image = EventStreamRecordingStatusView.symbol("trash", pointSize: 14)
        statusMenu = menu
        return item
    }

    @objc private func statusClicked(_ button: NSStatusBarButton) {
        guard EventStreamRecordingOwner.activeSessionID != nil, NSApp.currentEvent != nil,
              let statusMenu else { return }
        button.highlight(false)
        if warning.dismissIfShown() { return }

        statusView.isPressed = true
        defer {
            statusView.isPressed = false
            button.highlight(false)
        }
        let anchor = button.window?.contentView ?? button
        let x = button.convert(.zero, to: anchor).x
        statusMenu.appearance = NSApp.effectiveAppearance
        statusMenu.popUp(positioning: nil, at: NSPoint(x: x - 2, y: -6), in: anchor)
    }

    @objc private func stopClicked() {
        _ = finish(discarded: false)
    }

    @objc private func discardClicked() {
        guard let sessionID = EventStreamRecordingOwner.activeSessionID else { return }
        let previous = NSWorkspace.shared.frontmostApplication
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Are you sure you want to discard this recording?"
        alert.informativeText = "You can’t undo this action."
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn, EventStreamRecordingOwner.activeSessionID == sessionID {
            _ = finish(discarded: true)
        }
        previous?.activate()
    }

    /// Stops the active recording and hands its thread to `onRecordingEnded`.
    /// Returns false when there was no recording to stop.
    private func finish(discarded: Bool) -> Bool {
        guard let threadID = EventStreamRecordingOwner.stopFromControls(discarded: discarded) else { return false }
        onRecordingEnded(threadID, discarded)
        return true
    }
}
