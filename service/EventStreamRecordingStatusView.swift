import AppKit

@MainActor final class EventStreamRecordingStatusView: NSView {
    struct Layout {
        let iconCount: Int
        let overflow: String?
        let size: NSSize

        init(applicationCount: Int, symbolSize: NSSize, overflowWidth: CGFloat) {
            iconCount = min(applicationCount, 5)
            let hidden = applicationCount - iconCount
            overflow = hidden > 0 ? "+\u{2009}\(hidden)" : nil
            let iconWidth = iconCount == 0 ? 0 : 17 + CGFloat(iconCount - 1) * 12
            let width = 8 + iconWidth + (iconCount > 0 ? 4 : 0)
                + (overflow != nil ? overflowWidth + 4 : 0) + symbolSize.width + 6
            size = NSSize(width: width, height: max(17, symbolSize.height))
        }

        func applicationRect(at index: Int, in bounds: NSRect) -> NSRect {
            NSRect(x: bounds.minX + 8 + CGFloat(index) * 12, y: bounds.midY - 8.5, width: 17, height: 17)
        }
    }

    private static let overflowFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private let recordSymbol = EventStreamRecordingStatusView.symbol("record.circle", pointSize: 15)
    private var icons: [NSImage] = []
    private var layout = Layout(applicationCount: 0, symbolSize: .zero, overflowWidth: 0)
    var isPressed = false { didSet { if oldValue != isPressed { needsDisplay = true } } }

    func update(applications: [EventStreamObservedApplication]) -> CGFloat {
        let applicationIcons = applications.compactMap { app -> NSImage? in
            guard app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  app.bundleIdentifier != "com.apple.dock", let url = app.bundleURL else { return nil }
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return update(icons: applicationIcons)
    }

    @discardableResult
    func update(icons: [NSImage]) -> CGFloat {
        self.icons = Array(icons.prefix(5))
        let symbolSize = recordSymbol?.size ?? .zero
        let provisional = Layout(applicationCount: icons.count, symbolSize: symbolSize, overflowWidth: 0)
        let textWidth = provisional.overflow.map { Self.overflowText($0).size().width } ?? 0
        layout = Layout(applicationCount: icons.count, symbolSize: symbolSize, overflowWidth: textWidth)
        needsDisplay = true
        return layout.size.width
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawBackground()
            let graphic = NSRect(x: bounds.midX - layout.size.width / 2, y: bounds.midY - layout.size.height / 2,
                                 width: layout.size.width, height: layout.size.height)
            for index in icons.indices.reversed() {
                icons[index].draw(in: layout.applicationRect(at: index, in: graphic))
            }
            var x = graphic.minX + 8
            if !icons.isEmpty { x = layout.applicationRect(at: icons.count - 1, in: graphic).maxX + 4 }
            if let overflow = layout.overflow {
                let label = Self.overflowText(overflow)
                let size = label.size()
                label.draw(at: NSPoint(x: x, y: graphic.midY - size.height / 2))
                x += size.width + 4
            }
            if let recordSymbol {
                let size = recordSymbol.size
                let tinted = NSImage(size: size, flipped: false) { rect in
                    recordSymbol.draw(in: rect)
                    NSColor.controlTextColor.setFill()
                    rect.fill(using: .sourceIn)
                    return true
                }
                tinted.cacheMode = .never
                tinted.draw(in: NSRect(x: x, y: graphic.midY - size.height / 2, width: size.width, height: size.height))
            }
        }
    }

    private func drawBackground() {
        let vibrant: [NSAppearance.Name] = [
            .vibrantLight, .vibrantDark, .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark,
        ]
        guard effectiveAppearance.bestMatch(from: vibrant) != nil else { return }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let alpha: CGFloat = dark ? (isPressed ? 0.34 : 0.28) : (isPressed ? 0.15 : 0.10)
        (dark ? NSColor.white : .black).withAlphaComponent(alpha).setFill()
        let height = min(bounds.height, 24)
        let frame = NSRect(x: bounds.minX, y: bounds.midY - height / 2, width: bounds.width, height: height)
        NSBezierPath(roundedRect: frame, xRadius: height / 2, yRadius: height / 2).fill()
    }

    static func symbol(_ name: String, pointSize: CGFloat) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pointSize, weight: .regular))
        image?.isTemplate = true
        return image
    }

    private static func overflowText(_ value: String) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [.font: overflowFont, .foregroundColor: NSColor.controlTextColor])
    }
}
