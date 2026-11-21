import Foundation

@MainActor final class GuardianHelperLifecycle {
    let rendezvousName: String?
    let ignoredProcessID: Int32
    private let coordinator: any GuardianSessionCoordinator
    private let makeEnvironment: () -> any GuardianServerEnvironment
    private let terminate: @MainActor @Sendable () -> Void
    private let report: ((any Error)?) -> Void
    private(set) var session: CUALockScreenGuardianXPCSession?

    init(arguments: [String], parentProcessID: Int32,
         makeCoordinator: (Int32) -> any GuardianSessionCoordinator,
         makeEnvironment: @escaping () -> any GuardianServerEnvironment,
         terminate: @escaping @MainActor @Sendable () -> Void,
         report: @escaping ((any Error)?) -> Void = { _ in }) {
        rendezvousName = arguments.count >= 2 ? arguments[1] : nil
        ignoredProcessID = parentProcessID
        coordinator = makeCoordinator(parentProcessID)
        self.makeEnvironment = makeEnvironment
        self.terminate = terminate
        self.report = report
    }
    func applicationDidFinishLaunching() {
        guard let rendezvousName else { report(nil); terminate(); return }
        let session = CUALockScreenGuardianXPCSession(environment: makeEnvironment(), coordinator: coordinator,
                                                    onCleanupCompleted: terminate)
        do { try session.start(rendezvousName: rendezvousName); self.session = session }
        catch { report(error); terminate() }
    }
}
