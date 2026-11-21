import AppKit
import Foundation

extension ControllerApplicationTargetResolver.Environment {
    @MainActor static func native(workspace: NSWorkspace = .shared) -> Self {
        .init(bundleIdentifierAtPath: { Bundle(path:$0)?.bundleIdentifier },
            bundleIdentifierAtURL: { Bundle(url:$0)?.bundleIdentifier },
            canonicalURL: { $0.resolvingSymlinksInPath().standardizedFileURL },
            installedURLs: { workspace.urlsForApplications(withBundleIdentifier:$0) },
            runningURLs: { NSRunningApplication.runningApplications(withBundleIdentifier:$0).compactMap(\.bundleURL) },
            pathForName: {
                // Application path lookup by name is not an imported capability:
                // it simply calls this NSWorkspace selector.
                workspace.perform(NSSelectorFromString("fullPathForApplication:"),with:$0)?.takeUnretainedValue() as? String
            })
    }
}
