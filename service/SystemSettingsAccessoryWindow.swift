import AppKit
import SwiftUI

/// Apply after constructing the content controller, before the arrow.
@MainActor enum SettingsAccessoryWindowConfiguration {
    static let styleMask = NSWindow.StyleMask(rawValue: 32913)

    static func apply(to window: NSPanel, controller: NSViewController) {
        window.hasShadow = true
        window.level = .init(rawValue: 3)
        window.contentViewController = controller
        window.isMovableByWindowBackground = false
        window.isMovable = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.backgroundColor = NSColor.white.withAlphaComponent(0.001)
        window.isOpaque = false
        window.collectionBehavior = .init(rawValue: 586)
    }

    static func install(_ hostingView: NSView, in controller: NSViewController) {
        let root = NSView()
        controller.view = root
        root.addSubview(hostingView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: root.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        ])
    }
}

/// A hosting view that suppresses the safe area keeps the inherited public guide.
/// Its own additional guide covers the view; safe rect is frame and insets zero.
@MainActor final class SettingsAccessoryHostingView<Content: View>: NSHostingView<Content> {
    private var fullAreaGuide: NSLayoutGuide?

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }
    override var safeAreaRect: NSRect { frame }
    var fullContentLayoutGuide: NSLayoutGuide {
        if let fullAreaGuide { return fullAreaGuide }
        let guide = NSLayoutGuide()
        fullAreaGuide = guide
        return guide
    }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        let guide = fullContentLayoutGuide
        addLayoutGuide(guide)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            topAnchor.constraint(equalTo: guide.topAnchor),
            trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            bottomAnchor.constraint(equalTo: guide.bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
