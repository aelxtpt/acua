import AppKit

extension PermissionRowRegistryEnvironment where View == NSView {
    static var native: Self {
        .init(window: { view in
            guard let window = view.window else { return nil }
            return .init(contentView: { window.contentView },
                convertToScreen: { window.convertToScreen($0) },
                number: { window.windowNumber }, backingScale: { window.backingScaleFactor })
        }, layout: { $0.layoutSubtreeIfNeeded() }, bounds: { $0.bounds },
        convertToWindow: { $0.convert($1, to: nil) }, isDark: { view in
            let match = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
            return match == .darkAqua
        }, toQuartz: { point in
            quartzPoint(point, screenFrames: NSScreen.screens.map(\.frame))
        })
    }
    /// Screen lookups use the FIRST screen containing (0,0),
    /// not the first screen in the list. No matching screen uses maxY zero.
    static func quartzPoint(_ point: CGPoint, screenFrames: [CGRect]) -> CGPoint {
        .init(x: point.x, y: (screenFrames.first { $0.contains(.zero) }?.maxY ?? 0) - point.y)
    }
}
