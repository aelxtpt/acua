import AppKit

enum CursorCapture {
    struct Reference { let windowID: UInt32; let revision: UUID }
    // The feature/computerUseCursor preference, default true, read from
    // standardUserDefaults through the Foundation Bool bridge (NSNumber zero
    // is false).
    static var enabled: Bool { ComputerUseFeaturePreferences.cursorEnabled }

    /// Locate the existing overlay without changing the approved cursor artwork.
    /// The service owns this window; no windows of other applications are queried.
    static func visibleWindowID() -> UInt32? {
        let lookup = { () -> UInt32? in
            let windows = NSApplication.shared.windows.filter {
                $0 is NSPanel && $0.isVisible && $0.alphaValue > 0 && $0.ignoresMouseEvents && $0.level == .screenSaver
                    && ($0.contentView?.layer?.sublayers?.contains { $0.name == "agentLabel" } ?? false)
            }
            guard windows.count == 1, let id = UInt32(exactly: windows[0].windowNumber), id > 0 else { return nil }
            return id
        }
        return Thread.isMainThread ? lookup() : DispatchQueue.main.sync(execute: lookup)
    }
}
