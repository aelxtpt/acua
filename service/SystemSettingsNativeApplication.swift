import AppKit

/// A published native application handle is consumed on MainActor.
struct SystemSettingsNativeApplication: @unchecked Sendable {
    private let value: NSRunningApplication
    let processIdentifier: pid_t
    init(_ value: NSRunningApplication) { self.value = value; processIdentifier = value.processIdentifier }
    @MainActor var application: NSRunningApplication { value }
}
