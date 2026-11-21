import Foundation

@MainActor protocol ControllerFieldFocusBackend {
    func role() -> String
    func isFocusable() -> Bool
    func capturedFocused() -> Bool
    func bundleIdentifier() -> String?
    func supportsDOMClassList() -> Bool
    func setFocused() throws
    func uncachedFocused() -> Bool?
    func clickForFocus() async throws
}

/// Read focusability again in the general-focus path;
/// writing can refresh the captured element before its uncached focus probe.
@MainActor struct ControllerFieldFocus<Backend: ControllerFieldFocusBackend> {
    let backend: Backend
    func focusFieldIfNeeded() async throws {
        guard ["AXTextArea", "AXTextField", "AXDateTimeArea"].contains(backend.role()),
              backend.isFocusable(), !backend.capturedFocused() else { return }
        if backend.bundleIdentifier() == "com.apple.Safari", backend.supportsDOMClassList() {
            try await backend.clickForFocus()
        } else {
            try await focus()
        }
    }
    func focus() async throws {
        if backend.isFocusable() {
            try backend.setFocused()
            if backend.uncachedFocused() == true { return }
        }
        try await backend.clickForFocus()
    }
}
