import AppKit

struct ComputerUseApplicationTarget: Equatable {
    let bundleIdentifier: String
    let url: URL
    let identifier: String

    init(bundleIdentifier: String, url: URL) {
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.identifier = Self.identifier(for: url)
    }

    /// Matching uses the canonical decoded path, not the app name.
    static func identifier(for url: URL) -> String {
        var path = url.resolvingSymlinksInPath().standardizedFileURL.path(percentEncoded: false)
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

enum ComputerUseControllerIdentityError: Error, Equatable {
    case runningApplicationNotFound(String)
    case invalidProcessIdentifier(String, Int32)
}

/// Identity phase of controller construction. Observer/window setup
/// must still follow this phase in the native per-controller composition.
@MainActor struct ComputerUseControllerProcessIdentity<Application> {
    struct Environment {
        let runningApplications: @MainActor (String) -> [Application]
        let bundleURL: @MainActor (Application) -> URL?
        let resolvePID: @MainActor (Application) -> Int32
    }
    let target: ComputerUseApplicationTarget
    let application: Application
    let pid: Int32

    init(target: ComputerUseApplicationTarget, environment: Environment) throws {
        self.target = target
        guard let application = environment.runningApplications(target.bundleIdentifier).first(where: {
            environment.bundleURL($0).map { ComputerUseApplicationTarget.identifier(for: $0) == target.identifier } ?? false
        }) else { throw ComputerUseControllerIdentityError.runningApplicationNotFound(target.bundleIdentifier) }
        let pid = environment.resolvePID(application)
        guard pid > 0 else { throw ComputerUseControllerIdentityError.invalidProcessIdentifier(target.bundleIdentifier, pid) }
        self.application = application
        self.pid = pid
    }
}

extension ComputerUseControllerProcessIdentity where Application == NSRunningApplication {
    init(target: ComputerUseApplicationTarget) throws {
        try self.init(target: target, environment: .init(
            runningApplications: { NSRunningApplication.runningApplications(withBundleIdentifier: $0) },
            bundleURL: { $0.bundleURL }, resolvePID: RunningApplicationPID.resolve))
    }
}
