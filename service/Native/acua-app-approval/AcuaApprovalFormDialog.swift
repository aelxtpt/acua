import AppKit

/// Draws an `AcuaApprovalForm` as the service's own dialog, for MCP clients
/// that cannot show the elicitation form. Like the app approval dialog,
/// "Deny" is the default button, it closes unanswered after
/// `AcuaAppApprovalDialog.timeoutSeconds`, and a dismissal closes it.
@MainActor enum AcuaApprovalFormDialog {
    enum Answer {
        case allow([String: AcuaApprovalForm.Value])
        case deny
        case dismissed
    }

    private static let accessoryWidth: CGFloat = 380
    private static let textHeight: CGFloat = 96
    private static let pollSeconds: TimeInterval = 0.25

    static func ask(_ form: AcuaApprovalForm, dismissal: AcuaAppApprovalDismissal) -> Answer {
        guard !dismissal.isRequested else { return .dismissed }

        let alert = NSAlert()
        alert.messageText = form.message
        alert.informativeText = form.detail ?? "An agent connected to Aex Computer Use is asking for your approval."
        alert.alertStyle = .informational

        let controls = form.fields.map(FieldControl.init)
        if !controls.isEmpty {
            alert.accessoryView = accessory(controls)
        }

        // Button order fixes the modal responses mapped below.
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow")

        // The service is an accessory app: without this the dialog can open
        // behind the window the user is looking at.
        NSApp.activate()
        alert.window.level = .floating

        // Main-queue blocks do not run inside runModal's loop, so a dismissal
        // is noticed by a timer registered in the modal run-loop mode.
        let deadline = ProcessInfo.processInfo.systemUptime + AcuaAppApprovalDialog.timeoutSeconds
        let watcher = Timer(timeInterval: pollSeconds, repeats: true) { _ in
            guard dismissal.isRequested || ProcessInfo.processInfo.systemUptime >= deadline else { return }
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(watcher, forMode: .modalPanel)
        let response = alert.runModal()
        watcher.invalidate()

        switch response {
        case .alertFirstButtonReturn:
            return .deny
        case .alertSecondButtonReturn:
            var values: [String: AcuaApprovalForm.Value] = [:]
            for control in controls {
                values[control.key] = control.value
            }
            return .allow(values)
        default:
            return .dismissed
        }
    }

    private static func accessory(_ controls: [FieldControl]) -> NSView {
        let stack = NSStackView(views: controls.map(\.view))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.frame = NSRect(x: 0, y: 0, width: accessoryWidth, height: stack.fittingSize.height)
        return stack
    }

    /// One field's controls, and how to read the user's value back.
    @MainActor private struct FieldControl {
        let key: String
        let view: NSView
        let read: @MainActor () -> AcuaApprovalForm.Value

        var value: AcuaApprovalForm.Value { read() }

        init(_ field: AcuaApprovalForm.Field) {
            key = field.key

            switch field {
            case .text(_, let title, let detail, let value):
                let text = NSTextView(frame: NSRect(x: 0, y: 0, width: accessoryWidth, height: textHeight))
                text.string = value
                text.isRichText = false
                text.font = .systemFont(ofSize: NSFont.systemFontSize)
                let scroll = NSScrollView(frame: text.frame)
                scroll.documentView = text
                scroll.hasVerticalScroller = true
                scroll.borderType = .bezelBorder
                scroll.translatesAutoresizingMaskIntoConstraints = false
                scroll.widthAnchor.constraint(equalToConstant: accessoryWidth).isActive = true
                scroll.heightAnchor.constraint(equalToConstant: textHeight).isActive = true
                view = Self.labeled(title, detail: detail, content: scroll)
                read = { .text(text.string) }

            case .multipleChoice(_, let title, let options, let selected):
                let boxes = options.map { option -> NSButton in
                    let box = NSButton(checkboxWithTitle: option.title, target: nil, action: nil)
                    box.state = selected.contains(option.value) ? .on : .off
                    return box
                }
                let column = NSStackView(views: boxes)
                column.orientation = .vertical
                column.alignment = .leading
                view = Self.labeled(title, detail: nil, content: column)
                read = { .choices(zip(options, boxes).filter { $0.1.state == .on }.map { $0.0.value }) }

            case .choice(_, let title, let options, let selected):
                let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
                popUp.addItems(withTitles: options.map(\.title))
                if let selected, let index = options.firstIndex(where: { $0.value == selected }) {
                    popUp.selectItem(at: index)
                }
                view = Self.labeled(title, detail: nil, content: popUp)
                read = { .choice(options[max(popUp.indexOfSelectedItem, 0)].value) }

            case .toggle(_, let title, let isOn):
                let box = NSButton(checkboxWithTitle: title ?? field.key, target: nil, action: nil)
                box.state = isOn ? .on : .off
                view = box
                read = { .toggle(box.state == .on) }
            }
        }

        private static func labeled(_ title: String?, detail: String?, content: NSView) -> NSView {
            var views: [NSView] = []
            if let title {
                views.append(NSTextField(labelWithString: title))
            }
            views.append(content)
            if let detail {
                let label = NSTextField(wrappingLabelWithString: detail)
                label.textColor = .secondaryLabelColor
                label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                views.append(label)
            }

            let column = NSStackView(views: views)
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 4
            return column
        }
    }
}
