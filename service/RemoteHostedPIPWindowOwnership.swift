enum RemoteHostedPIPWindowOwnership {
    static func ownerWindowID(for windowID: UInt32, role: String, subrole: String?, isModal: Bool,
        parentWindowID: UInt32?, mostRecentWindowID: UInt32?, mainWindowID: UInt32?,
        existingParentWindowID: UInt32?) -> UInt32? {
        func valid(_ candidate: UInt32?) -> UInt32? {
            guard let candidate, candidate != 0, candidate != windowID else { return nil }
            return candidate
        }
        if role == "AXSheet" {
            // Presence wins over validity: an invalid explicit parent does not
            // fall back to the existing owner.
            return valid(parentWindowID ?? existingParentWindowID)
        }
        guard role == "AXWindow" else { return nil }
        if let parentWindowID { return valid(parentWindowID) }
        guard subrole == "AXDialog", isModal else { return nil }
        return valid(mostRecentWindowID) ?? valid(mainWindowID)
    }
}
