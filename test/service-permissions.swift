import Foundation

@MainActor private final class Presenter: ServiceSystemPermissionPresenter {
    let configuration: ServiceSystemPermissions.PresenterConfiguration
    var calls = [(Set<ServicePermissionRequirement>, ServicePermissionSource, Bool)]()
    var result = ServicePermissionPresentationResult.pending
    init(_ configuration: ServiceSystemPermissions.PresenterConfiguration) { self.configuration = configuration }
    func present(requirements: Set<ServicePermissionRequirement>, source: ServicePermissionSource,
                 treatDismissalAsAbandonment: Bool) async -> ServicePermissionPresentationResult {
        calls.append((requirements, source, treatDismissalAsAbandonment)); return result
    }
}

@MainActor private final class World {
    var presenters = [Presenter]()
    func make(state: ServiceSystemPermissions.State = .init()) -> ServiceSystemPermissions {
        .init(state: state, environment: .init(makePresenter: { [self] configuration in
            let presenter = Presenter(configuration); presenters.append(presenter); return presenter
        }))
    }
}

@main enum ServicePermissionTests {
    @MainActor static func main() async throws {
        var cases = [String]()
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            precondition(condition(), name); cases.append(name)
        }
        for (value, name) in [(ServicePermissionGrantState.none, "none_granted"), (.accessibility, "accessibility_granted"),
                              (.screenRecording, "screen_recording_granted"), (.both, "both_granted")] {
            let state = try ServicePermissionResult.appshotPermissionsAbandoned(value).appshotPermissionState()
            check("abandonment-\(value.rawValue)-is-a-present-wire-state", state?.rawValue == name)
        }
        let granted = try ServicePermissionResult.granted.appshotPermissionState()
        check("granted-is-the-only-nil-success", granted == nil)
        for (result, code, description) in [(ServicePermissionResult.pending, CUErrorCode.permissionsPending, "Computer Use permissions are still pending"),
                                           (.denied, .permissionsNotGranted, "Computer Use permissions are not granted")] {
            do { _ = try result.appshotPermissionState(); preconditionFailure("Missing permission error") }
            catch let error as ServiceError { check("presentation-error-\(code.rawValue)-preserved", error.code == code && error.message == description) }
        }
        let duration = ServicePermissionWindowConfiguration.pendingTimeout
        let words = withUnsafeBytes(of: duration) { (raw: UnsafeRawBufferPointer) in
            (raw.loadUnaligned(fromByteOffset: 0, as: UInt64.self), raw.loadUnaligned(fromByteOffset: 8, as: UInt64.self))
        }
        check("window-timeout-is-110-seconds-in-128-bit-attoseconds", words.0 == 0xF68E8131ECF80000 && words.1 == 5 && duration == .seconds(110))

        let world = World()
        let core = world.make()
        let appshot = await core.ensure(source: .appshot, appshotRequestID: "")
        check("appshot-creates-presenter-when-not-ready", appshot == .pending && world.presenters.count == 1 && world.presenters[0].configuration.source == .appshot)
        check("empty-present-id-is-retained-after-pending", core.appshotRequestIDs == [""])
        let computer = await core.ensure(source: .computerUse, appshotRequestID: nil)
        check("later-request-reuses-open-presenter", computer == .pending && world.presenters.count == 1 && world.presenters[0].calls.map(\.1) == [.appshot, .computerUse])
        check("nil-id-does-not-set-abandonment-flag", world.presenters[0].calls[0].2 && !world.presenters[0].calls[1].2)
        core.updatePermission(.accessibility, outcome: .denied)
        core.updatePermission(.screenRecording, outcome: .denied)
        world.presenters[0].configuration.onClose()
        check("close-caches-none-for-present-empty-id", core.abandoned[""] == .some(.none) && !core.hasPresenter && core.appshotRequestIDs.isEmpty)
        core.updatePermission(.accessibility, outcome: .granted)
        core.updatePermission(.screenRecording, outcome: .granted)
        let abandoned = await core.ensure(source: .appshot, appshotRequestID: "")
        check("cached-none-precedes-new-grants-and-maps-to-present-state", abandoned == .appshotPermissionsAbandoned(.none) && (try? abandoned.appshotPermissionState()) == .some(.none))
        let fresh = await core.ensure(source: .appshot, appshotRequestID: "fresh")
        check("new-id-uses-cached-ready-state-without-new-presenter", fresh == .granted && world.presenters.count == 1)

        let historyWorld = World(), history = historyWorld.make(state: .init(accessibility: true))
        let historyResult = await history.ensure(source: .timeline, appshotRequestID: nil)
        check("history-ready-needs-only-accessibility", historyResult == .granted && historyWorld.presenters.isEmpty)
        let appshotResult = await history.ensure(source: .appshot, appshotRequestID: "same-service")
        check("same-service-appshot-still-needs-screen-recording", appshotResult == .pending && historyWorld.presenters.count == 1)

        try JSONSerialization.data(withJSONObject: ["passed": true, "cases": cases,
            "native_UI_or_input_or_desktop_capture_executed": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print("Service permission edges: \(cases.count) checks")
    }
}
