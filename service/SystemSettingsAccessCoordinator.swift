import Foundation
import CoreGraphics

enum SystemSettingsPrivacyPermissionError: UInt8, Error, CustomNSError, Sendable {
    case requiresUserDragAndDrop, userCancelled
    static var errorDomain: String { "ComputerUse.SystemSettingsPrivacyPermissionError" }
    var errorCode: Int { Int(rawValue) }
    var errorUserInfo: [String:Any] { [:] }
}

// Permission/window values do not depend on transition artwork. Keeping their
// metadata outside the generic actor owner also avoids Swift6.4 optimized
// destruction failures for a nested Permission with an unused NSImage argument.
struct SystemSettingsPrivacyPermission<Application: Sendable>: Sendable {
    let identifier: String
    let destination: SystemSettings.Destination
    let validate: @Sendable (Application) -> Bool
}
struct SystemSettingsAccessPermission<Application: Sendable>: Sendable {
    let identifier: String
    let grant: @Sendable () async throws -> Bool
    let privacy: SystemSettingsPrivacyPermission<Application>?
}
struct SystemSettingsAccessWindow: Sendable {
    let frame: CGRect
    let isOnscreen: Bool?
}

/// Native permission, settings tracking and presentation are
/// explicit providers; the request and fallback lifetimes are owned here.
@MainActor final class SystemSettingsAccessCoordinator<Application: Sendable, Capture: Sendable> {
    enum RequestError: Error, CustomNSError, Sendable {
        case requestAlreadyInProgress(String)
        nonisolated static var errorDomain: String { "ComputerUse.SystemSettingsAccessCoordinator.RequestError" }
        nonisolated var errorCode: Int { 0 }
        nonisolated var errorUserInfo: [String:Any] { [:] }
    }
    typealias PrivacyPermission = SystemSettingsPrivacyPermission<Application>
    typealias Permission = SystemSettingsAccessPermission<Application>
    typealias Window = SystemSettingsAccessWindow
    typealias Condition = @MainActor @Sendable () async -> Bool
    struct Environment: Sendable {
        let open: @MainActor @Sendable (SystemSettings.Destination, Bool) async throws -> Application
        let windows: @MainActor @Sendable (Application) -> [Window]
        let activate: @MainActor @Sendable (Application) -> Void
        let preventActivation: @MainActor @Sendable (Application) async -> Void
        let reenableActivation: @MainActor @Sendable () async -> Void
        let presentAccessory: @MainActor @Sendable (Application, PrivacyPermission) async throws -> Void
        let prepareTransition: @MainActor @Sendable (Capture?) -> Void
        let clearSettingsTracking: @MainActor @Sendable () -> Void
        let cleanupPresentation: @MainActor @Sendable () -> Void
        let hasNoDialogs: @MainActor @Sendable (Application) -> Bool
        let pollUntilTrue: @MainActor @Sendable (Double, Double, @escaping Condition) async throws -> Void
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for:$0) }
        var scheduleDragResume: @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void = { operation in
            Task { @MainActor in operation() }
        }
    }
    private final class AuthorizationFlag: @unchecked Sendable {
        private let lock=NSLock()
        private var value=false
        func set() { lock.withLock { value=true } }
        func get() -> Bool { lock.withLock { value } }
    }
    let environment: Environment
    var onAccessoryTransitionStart: (@MainActor @Sendable () -> Void)?
    var onAccessoryReverseTransitionCompletion: (@MainActor @Sendable () -> Void)?
    private(set) var activePermissionIdentifier: String?
    private(set) var requestingPrivacyPermission: PrivacyPermission?
    private(set) var transitionSource: Capture?
    private(set) var shouldPresentAccessoryWithoutTransition=false
    private(set) var shouldActivateSystemSettingsAfterAccessoryPresentation=false
    private var dragContinuation: CheckedContinuation<Void, any Error>?
    var isWaitingForDrag: Bool { dragContinuation != nil }

    init(environment: Environment) { self.environment=environment }
    @discardableResult func requestAccess(to permission: Permission, sourceCapture: Capture? = nil) async throws -> Bool {
        if let activePermissionIdentifier { throw RequestError.requestAlreadyInProgress(activePermissionIdentifier) }
        activePermissionIdentifier=permission.identifier
        defer { activePermissionIdentifier=nil }
        do { return try await permission.grant() }
        catch SystemSettingsPrivacyPermissionError.requiresUserDragAndDrop {
            guard let privacy=permission.privacy else { throw SystemSettingsPrivacyPermissionError.requiresUserDragAndDrop }
            try await requestPrivacyAccess(privacy,sourceCapture:sourceCapture)
            return true
        }
    }
    private func requestPrivacyAccess(_ permission: PrivacyPermission, sourceCapture: Capture?) async throws {
        // Cancellation before state setup has no presentation cleanup side effects.
        try Task.checkCancellation()
        requestingPrivacyPermission=permission;transitionSource=sourceCapture
        environment.prepareTransition(sourceCapture)
        shouldActivateSystemSettingsAfterAccessoryPresentation=true
        defer { cleanupRequest() }
        let application=try await environment.open(permission.destination,false)
        if Self.shouldActivateInitially(environment.windows(application)) { environment.activate(application) }
        await environment.preventActivation(application)
        try await environment.presentAccessory(application,permission)
        try Task.checkCancellation()
        let authorized=AuthorizationFlag()
        let sleep=environment.sleep
        let validate: @Sendable () -> Bool = { permission.validate(application) }
        let foundAuthorization: @MainActor @Sendable () -> Void = { [self] in
            environment.clearSettingsTracking();cleanupPresentation()
        }
        let waitForDrag: @MainActor @Sendable () async throws -> Void = { [self] in try await waitForDragCompletion() }
        try await withThrowingTaskGroup(of:Void.self) { group in
            group.addTask { await Self.watchAuthorization(validate,flag:authorized,sleep:sleep,found:foundAuthorization) }
            group.addTask { try await waitForDrag() }
            _ = try await group.next()
            group.cancelAll()
            // Drain remaining children before leaving the group.
            while !group.isEmpty { _ = try await group.next() }
        }
        try Task.checkCancellation()
        if !authorized.get() {
            try await environment.pollUntilTrue(120,0.1) { permission.validate(application) }
        }
        await environment.reenableActivation()
        try await environment.sleep(.milliseconds(500))
        try await environment.pollUntilTrue(120,0.1) { [environment] in environment.hasNoDialogs(application) }
    }
    // The validator child runs off MainActor. Its normal sleep errors are ignored;
    // cancellation is observed at the loop head, not thrown from this child.
    nonisolated private static func watchAuthorization(_ validate: @Sendable () -> Bool,
        flag: AuthorizationFlag, sleep: @Sendable (Duration) async throws -> Void,
        found: @MainActor @Sendable () -> Void) async {
        while !Task.isCancelled {
            if validate() { flag.set();await found();return }
            try? await sleep(.milliseconds(100))
        }
    }
    // An empty array intentionally does not activate Settings.
    static func shouldActivateInitially(_ windows: [Window]) -> Bool {
        !windows.isEmpty && !windows.contains { $0.frame.width > 600 && $0.frame.height >= 470 && $0.isOnscreen == true }
    }
    static func hasNoDialogs(inOnscreenWindows windows: [Window]) -> Bool {
        windows.allSatisfy { $0.frame.width > 600 && $0.frame.height >= 470 }
    }
    func openSettingsAndPresentAccessoryIfNeeded(for permission: PrivacyPermission) async throws {
        shouldPresentAccessoryWithoutTransition=true
        defer { shouldPresentAccessoryWithoutTransition=false }
        let application=try await environment.open(permission.destination,true)
        if requestingPrivacyPermission?.identifier == permission.identifier {
            try await environment.presentAccessory(application,permission)
        }
    }
    func waitForDragCompletion() async throws {
        // Replacing a stored waiter fails that waiter with Cocoa userCancelled.
        // Cancellation/drop resumes whichever waiter is current, without a UUID.
        dragContinuation?.resume(throwing:CocoaError(.userCancelled))
        let schedule=environment.scheduleDragResume
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { dragContinuation=$0 }
        } onCancel: { [self] in schedule { [self] in completeCurrentDrag() } }
    }
    func notifyDragCompleted() {
        environment.scheduleDragResume { [self] in completeCurrentDrag() }
    }
    // Drop and drag completion deliver their continuation result synchronously
    // after presentation/tracking cleanup, unlike the cancellation-handler task.
    func finishPrivacyDrop() { completeCurrentDrag() }
    func cancelPrivacyDrag() {
        dragContinuation?.resume(throwing:SystemSettingsPrivacyPermissionError.userCancelled)
        dragContinuation=nil
    }
    func accessoryTransitionStarted() { onAccessoryTransitionStart?() }
    func accessoryReverseTransitionCompleted() { onAccessoryReverseTransitionCompletion?() }
    private func completeCurrentDrag() {
        dragContinuation?.resume()
        dragContinuation=nil
    }
    private func cleanupPresentation() {
        environment.cleanupPresentation();transitionSource=nil
    }
    private func cleanupRequest() {
        environment.clearSettingsTracking();cleanupPresentation()
        requestingPrivacyPermission=nil
        shouldActivateSystemSettingsAfterAccessoryPresentation=false
    }
    deinit {
        // The destructor assumes the main executor and only cleans the
        // transition/session/accessory; it does not resume a pending drag.
        MainActor.assumeIsolated { environment.cleanupPresentation() }
    }
}
