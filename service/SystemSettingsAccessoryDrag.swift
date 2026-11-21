import AppKit
import SwiftUI

@MainActor protocol SettingsAccessoryDragDelegate: AnyObject {
    func settingsAccessoryDidDrop(at point: CGPoint)
}

@MainActor protocol SettingsAccessoryDraggingSession: AnyObject {
    var animatesToStartingPositionsOnCancelOrFail: Bool { get set }
}
extension NSDraggingSession: SettingsAccessoryDraggingSession {}

/// FACDFC: view-owned bitmap rendering; this does not capture the desktop.
@MainActor enum SettingsAccessoryViewSnapshot {
    static func image(of view: NSView, in rect: CGRect) -> NSImage? {
        if let scroll = view as? NSScrollView {
            let clip = scroll.contentView
            return image(of: clip, in: view.convert(rect, to: clip))
        }
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        bitmap.size = rect.size
        view.cacheDisplay(in: rect, to: bitmap)
        let image = NSImage(size: rect.size)
        image.addRepresentation(bitmap)
        return image
    }
}

/// Native column with lazy pasteboard data and a fixed drag order.
@MainActor final class SettingsAccessoryDraggableView: NSView, NSDraggingSource, NSPasteboardItemDataProvider {
    typealias BeginSession = @MainActor ([NSDraggingItem], NSEvent, any NSDraggingSource) -> any SettingsAccessoryDraggingSession
    let box = NSBox()
    let appRowView: NSHostingView<SettingsAccessoryApplicationLabel>
    let hintView: NSHostingView<SettingsAccessoryDragHint>
    let applicationBundleURL: URL?
    weak var dragDelegate: (any SettingsAccessoryDragDelegate)?
    private let beginSession: BeginSession?
    private let currentBundleURL: @Sendable () -> URL?
    private let snapshot: @MainActor (NSView, CGRect) -> NSImage?

    init(applicationName: String, applicationBundleURL: URL?, icon: NSImage,
         destination: SystemSettings.Destination?, hintArrow: NSImage?,
         beginSession: BeginSession? = nil,
         currentBundleURL: @escaping @Sendable () -> URL? = { NSRunningApplication.current.bundleURL },
         snapshot: @escaping @MainActor (NSView, CGRect) -> NSImage? = { SettingsAccessoryViewSnapshot.image(of: $0, in: $1) }) {
        self.applicationBundleURL = applicationBundleURL
        self.beginSession = beginSession
        self.currentBundleURL = currentBundleURL
        self.snapshot = snapshot
        appRowView = NSHostingView(rootView: SettingsAccessoryApplicationLabel(applicationName: applicationName, icon: icon))
        hintView = NSHostingView(rootView: SettingsAccessoryDragHint(applicationName: applicationName, destination: destination, hintArrow: hintArrow, showsHintArrow: false))
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.cornerRadius = 7
        updateBoxAppearance()
        addSubview(box)
        box.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            box.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            box.heightAnchor.constraint(equalToConstant: 42),
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        ])
        box.addSubview(appRowView)
        box.contentView = appRowView
        box.contentViewMargins = NSSize(width: 4, height: 5)
        addSubview(hintView)
        hintView.setContentCompressionResistancePriority(.required, for: .vertical)
        hintView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hintView.bottomAnchor.constraint(equalTo: box.topAnchor, constant: -7),
            hintView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBoxAppearance()
    }

    private func updateBoxAppearance() {
        let match = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        let dark = match == .darkAqua || match == .vibrantDark
        box.fillColor = (dark ? NSColor.black : NSColor.white).withAlphaComponent(dark ? 0.06 : 0.65)
        box.borderColor = dark ? SettingsAccessoryAssets.adaptivePrimary.withAlphaComponent(0.08)
            : NSColor(red: 223.0 / 255, green: 221.0 / 255, blue: 227.0 / 255, alpha: 1)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func makeDraggingItem() -> NSDraggingItem {
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.fileURL])
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let bounds = appRowView.bounds
        dragging.setDraggingFrame(convert(bounds, from: appRowView), contents: snapshot(appRowView, bounds))
        return dragging
    }

    override func mouseDown(with event: NSEvent) {
        let item = makeDraggingItem()
        let session: any SettingsAccessoryDraggingSession
        if let beginSession { session = beginSession([item], event, self) }
        else { session = beginDraggingSession(with: [item], event: event, source: self) }
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func sourceOperation(for context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { sourceOperation(for: context) }

    func dragWillBegin() { appRowView.isHidden = true }
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) { dragWillBegin() }

    func dragDidEnd(at point: CGPoint, operation: NSDragOperation) {
        let delegate = dragDelegate
        if operation == .copy { delegate?.settingsAccessoryDidDrop(at: point) }
        appRowView.isHidden = false
    }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragDidEnd(at: screenPoint, operation: operation) }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        guard type == .fileURL else { return }
        guard let url = applicationBundleURL ?? currentBundleURL() else { return }
        if let pasteboard { pasteboard.setData(url.dataRepresentation, forType: .fileURL) }
    }
}

struct SettingsAccessoryDragHost: NSViewRepresentable {
    let source: SettingsAccessoryDraggableView
    func makeNSView(context: Context) -> SettingsAccessoryDraggableView { source }
    func updateNSView(_ nsView: SettingsAccessoryDraggableView, context: Context) {}
}
