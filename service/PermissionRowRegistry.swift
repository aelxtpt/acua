import Foundation
import CoreGraphics

struct PermissionActionLocation: Sendable, Equatable {
    let point: CGPoint
    let windowID: UInt32
}

/// Window identity is captured before layout. Native effects are supplied by
/// the AppKit adapter; tests can exercise the same reentrant lookup algorithm.
@MainActor struct PermissionRowRegistryWindow<View: AnyObject> {
    let contentView: () -> View?
    let convertToScreen: (CGRect) -> CGRect
    let number: () -> Int
    let backingScale: () -> CGFloat
}
@MainActor struct PermissionRowRegistryEnvironment<View: AnyObject> {
    let window: (View) -> PermissionRowRegistryWindow<View>?
    let layout: (View) -> Void
    let bounds: (View) -> CGRect
    let convertToWindow: (View, CGRect) -> CGRect
    let isDark: (View) -> Bool
    let toQuartz: (CGPoint) -> CGPoint
}

/// Dead weak views do not remove entries or their
/// retained snapshot providers. Source/action registration updates independently.
@MainActor final class PermissionRowRegistry<Requirement: Hashable, View: AnyObject, Artwork: Sendable> {
    typealias SnapshotProvider = @MainActor @Sendable (CGSize, CGFloat, Bool) -> Artwork?
    typealias Environment = PermissionRowRegistryEnvironment<View>
    private final class Entry {
        weak var sourceView: View?
        weak var actionView: View?
        var snapshotProvider: SnapshotProvider?
    }
    let environment: Environment
    private var entries = [Requirement: Entry]()
    var entryCount: Int { entries.count }
    init(environment: Environment) { self.environment = environment }

    func registerSource(_ view: View?, snapshotProvider: SnapshotProvider?, for requirement: Requirement) {
        let entry = entries[requirement] ?? Entry()
        entry.sourceView = view
        entry.snapshotProvider = snapshotProvider
        entries[requirement] = entry
    }
    func registerAction(_ view: View?, for requirement: Requirement) {
        let entry = entries[requirement] ?? Entry()
        entry.actionView = view
        entries[requirement] = entry
    }
    func actionLocation(for requirement: Requirement) -> PermissionActionLocation? {
        guard let view = entries[requirement]?.actionView, let window = environment.window(view) else { return nil }
        if let content = window.contentView() { environment.layout(content) }
        environment.layout(view)
        let frame = window.convertToScreen(environment.convertToWindow(view, environment.bounds(view)))
        let point = environment.toQuartz(.init(x: frame.midX, y: frame.midY))
        // Invalid native window numbers trap instead of
        // being clamped or silently dropped. Zero remains a valid conversion.
        let identifier = UInt32(exactly: window.number())!
        return .init(point: point, windowID: identifier)
    }
    func capture(for requirement: Requirement) -> SettingsAccessoryCapture<Artwork>? {
        guard let view = entries[requirement]?.sourceView,
              let window = environment.window(view), let content = window.contentView() else { return nil }
        environment.layout(content)
        environment.layout(view)
        let frame = window.convertToScreen(environment.convertToWindow(view, environment.bounds(view))).integral
        // Layout can replace the entry. Use its CURRENT provider with the
        // view/window retained at registration and freshly read bounds/scale/theme.
        var artwork: Artwork?
        if let provider = entries[requirement]?.snapshotProvider {
            let size = environment.bounds(view).size
            let scale = window.backingScale()
            let dark = environment.isDark(view)
            artwork = provider(size, scale, dark)
        }
        return .init(frameOnScreen: frame, artwork: artwork, cornerRadius: 24)
    }
}
