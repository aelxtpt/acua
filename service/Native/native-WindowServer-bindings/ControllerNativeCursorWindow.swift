import AppKit
import Darwin
import Foundation

@MainActor final class ControllerNativeCursorWindow: NSPanel, NSWindowDelegate {
    var stopCursorMotion: () -> Void = {}
    var cursorStyleUpdated: () -> Void = {}
    var tipOffset: CGPoint = .zero
    private var spaceObservation: ControllerCursorNativeLease?
    lazy var monitorWindow = ControllerCursorMonitorWindow(isVisible: { [weak self] in self?.isVisible == true },
        setApplicationReason: { [weak self] in self?.ordering.setApplicationReason($0) },
        retarget: { [weak self] in self?.ordering.retargetVisibleWindow($0) })
    private lazy var ordering = ControllerCursorWindowOrdering(environment: .init(
        number: { [weak self] in self?.windowNumber ?? 0 },
        visibleNumbers: { NSWindow.windowNumbers(options: [.allApplications])?.map(\.intValue) },
        targetLevel: { id in
            guard let info = WindowDescription.lookup(id) else { return nil }
            return (info[kCGWindowLayer as String] as? NSNumber)?.intValue
        }, setServerOverlayLevel: { Self.setServerOverlayLevel($0) },
        setLevel: { [weak self] in self?.level = .init(rawValue: $0) }, front: { [weak self] in self?.orderFront(nil) },
        above: { [weak self] in self?.order(.above, relativeTo: Int($0)) }, isVisible: { [weak self] in self?.isVisible == true },
        orderOut: { [weak self] in self?.primitiveOrderOut() }, stopMotion: { [weak self] in self?.stopCursorMotion() },
        styleUpdated: { [weak self] in self?.cursorStyleUpdated() }, occlusionRawValue: { [weak self] in self?.occlusionState.rawValue ?? 0 },
        windowBelowTip: { [weak self] in
            guard let self else { return 0 }
            let point = CGPoint(x: frame.minX + tipOffset.x, y: frame.minY + tipOffset.y)
            return UInt32(NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: windowNumber))
        }))
    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        delegate = self
        let center = NSWorkspace.shared.notificationCenter
        let token = center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.ordering.activeSpaceChanged() }
        }
        spaceObservation = .init { center.removeObserver(token) }
    }
    required init?(coder: NSCoder) { fatalError("Cursor windows use the designated initializer") }
    func showForCursor(relativeTo target: UInt32?, temporaryOverlay: Bool) { ordering.show(relativeTo: target, overlay: temporaryOverlay) }
    func cursorMoved() { ordering.moved() }
    func stopMotionBeforeNextMove() { ordering.stopMotion() }
    func clearMovementReason() { ordering.clearMovementReason() }
    var hasTemporaryMovementReason: Bool { ordering.movementReason }
    override func orderOut(_ sender: Any?) { ordering.hide() }
    private func primitiveOrderOut() { super.orderOut(nil) }
    func windowDidChangeOcclusionState(_ notification: Notification) { ordering.occlusionChanged() }
    func windowDidChangeScreen(_ notification: Notification) { ordering.screenChanged(hasScreen: screen != nil) }

    /// WindowServerSPI preserves its complete connection pointer.
    private struct LevelFunctions {
        typealias Main = @convention(c) () -> OpaquePointer?
        typealias Set = @convention(c) (OpaquePointer?, UInt32, Int32) -> CGError
        let main: Main
        let set: Set
    }
    private static let levelFunctions: LevelFunctions? = .init(
        main: { ControllerWindowServerOperations.native.mainConnection() },
        set: { ControllerWindowServerOperations.native.setLevel($2, window: $1, connection: $0) })
    private static func setServerOverlayLevel(_ window: UInt32) {
        guard let functions = levelFunctions else { return }
        let level = CGWindowLevelForKey(.overlayWindow)
        _ = functions.set(functions.main(), window, level)
    }
}
