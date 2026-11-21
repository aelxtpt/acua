import CoreGraphics

// Plain value snapshot of one AX element, fed to the pure password-entry chooser.
struct LockScreenPasswordEntryCandidate {
    var role: String?
    var identifier: String?
    var value: String?
    var isEnabled: Bool?
    var frame: CGRect?
}
