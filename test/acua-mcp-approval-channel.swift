import Foundation
import MCP

// Unit tests for MCP app approval in the client when the MCP host does not
// support elicitation: the channel is chosen from the capabilities declared at
// initialize, and the service dialog's decision maps onto the approval store.
// The service is a fake; no request leaves the process.

private final class DialogRecorder: @unchecked Sendable {
    var requests: [String] = []
}

@main
enum AcuaMCPApprovalChannelTests {
    private static var passed = 0

    // -O strips precondition messages, so a failure names itself and exits.
    private static func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        guard condition else {
            print("FAIL \(name) \(detail())")
            exit(1)
        }

        passed += 1
        print("PASS \(name)")
    }

    private static let bundle = "com.apple.TextEdit"
    private static let arguments = AutomationMCPArguments(["app": .string(bundle)])

    private static func policy(_ decision: ComputerUseIPCAppPolicyDecision) -> AutomationMCPApproval.Policy {
        { _ in
            .init(decision: decision, target: .init(bundleIdentifier: bundle, displayName: "TextEdit",
                appPath: "/System/Applications/TextEdit.app", risk: .low, warningSubtitle: nil),
                allowPersistentApproval: true)
        }
    }

    private static func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("acua-approval-\(UUID().uuidString).json")
    }

    private static func dialog(_ decision: ComputerUseIPCAppApprovalDecision,
                               _ recorder: DialogRecorder) -> AutomationMCPApprovalChannel {
        .serviceDialog { request in
            recorder.requests.append(request.app)
            return .init(decision: decision)
        }
    }

    private static func approval(_ channel: AutomationMCPApprovalChannel, store: AppApprovalStore,
                                 policy decision: ComputerUseIPCAppPolicyDecision = .allowed) -> AutomationMCPApproval {
        AutomationMCPApproval(store: store, policy: policy(decision), channel: channel, telemetry: { _ in })
    }

    private static func thrown(_ body: () async throws -> Void) async -> (any Error)? {
        do {
            try await body()
            return nil
        } catch {
            return error
        }
    }

    static func main() async throws {
        // Channel selection from the initialize capabilities.
        check("SupportsFormElicitation_NoElicitationCapability_False",
              !CUAMCPClientCapabilities.supportsFormElicitation(.init()))
        check("SupportsFormElicitation_EmptyElicitationObject_True",
              CUAMCPClientCapabilities.supportsFormElicitation(.init(elicitation: .init())))
        check("SupportsFormElicitation_UrlModeOnly_False",
              !CUAMCPClientCapabilities.supportsFormElicitation(.init(elicitation: .init(form: nil, url: .init()))))
        let declared = try JSONDecoder().decode(Client.Capabilities.self, from: Data(#"{"elicitation":{}}"#.utf8))
        check("SupportsFormElicitation_DecodedEmptyObject_True", CUAMCPClientCapabilities.supportsFormElicitation(declared))

        let unrecorded = CUAMCPClientCapabilities()
        check("ClientCapabilities_BeforeInitialize_NoElicitation", !unrecorded.supportsElicitation)
        let recorded = CUAMCPClientCapabilities()
        recorded.record(.init(elicitation: .init()))
        check("ClientCapabilities_RecordedElicitation_SupportsElicitation", recorded.supportsElicitation)

        // Pre-approved by [apps].allow: authorized, nothing stored.
        let preStore = AppApprovalStore(storageURL: temporaryStoreURL())
        let preDialog = DialogRecorder()
        let pre = try await approval(dialog(.preApproved, preDialog), store: preStore).authorize(.getAppState, arguments: arguments)
        check("Authorize_ServiceDialogPreApproved_AuthorizedWithoutPrompt",
              pre == .init(bundleIdentifier: bundle, requestedApproval: false) && preDialog.requests == [bundle], "\(String(describing: pre))")
        check("Authorize_ServiceDialogPreApproved_StoresNoApproval", !(await preStore.isApproved(bundle)))

        // Allowed for the session: stored in memory only; no second dialog.
        let sessionURL = temporaryStoreURL()
        let sessionStore = AppApprovalStore(storageURL: sessionURL)
        let sessionDialog = DialogRecorder()
        let sessionApproval = approval(dialog(.allowedForSession, sessionDialog), store: sessionStore)
        let session = try await sessionApproval.authorize(.getAppState, arguments: arguments)
        check("Authorize_ServiceDialogAllowedForSession_RequestedApproval",
              session == .init(bundleIdentifier: bundle, requestedApproval: true))
        _ = try await sessionApproval.authorize(.click, arguments: arguments)
        check("Authorize_AllowedForSessionThenAnotherCall_NoSecondDialog", sessionDialog.requests.count == 1,
              "\(sessionDialog.requests)")
        check("Authorize_AllowedForSession_NotPersisted", !(await AppApprovalStore(storageURL: sessionURL).isApproved(bundle)))

        // Always allowed: persisted for the next client process.
        let alwaysURL = temporaryStoreURL()
        let alwaysDialog = DialogRecorder()
        _ = try await approval(dialog(.allowedAlways, alwaysDialog), store: AppApprovalStore(storageURL: alwaysURL))
            .authorize(.getAppState, arguments: arguments)
        check("Authorize_ServiceDialogAllowedAlways_Persisted", await AppApprovalStore(storageURL: alwaysURL).isApproved(bundle))

        let denied = await thrown {
            _ = try await approval(dialog(.denied, DialogRecorder()), store: AppApprovalStore(storageURL: temporaryStoreURL()))
                .authorize(.getAppState, arguments: arguments)
        }
        let deniedInDialog: Bool
        if case .appApprovalDeniedInDialog(let app)? = denied as? MCPToolError { deniedInDialog = app == bundle } else { deniedInDialog = false }
        check("Authorize_ServiceDialogDenied_ThrowsDeniedInDialog", deniedInDialog, "\(String(describing: denied))")

        let canceled = await thrown {
            _ = try await approval(dialog(.canceled, DialogRecorder()), store: AppApprovalStore(storageURL: temporaryStoreURL()))
                .authorize(.getAppState, arguments: arguments)
        }
        let canceledByUser: Bool
        if case .appApprovalCanceled(let app)? = canceled as? MCPToolError { canceledByUser = app == bundle } else { canceledByUser = false }
        check("Authorize_ServiceDialogCanceled_ThrowsCanceled", canceledByUser, "\(String(describing: canceled))")

        // Policy refusal comes first: the dialog is never asked.
        let blockedDialog = DialogRecorder()
        let blocked = await thrown {
            _ = try await approval(dialog(.allowedAlways, blockedDialog), store: AppApprovalStore(storageURL: temporaryStoreURL()),
                                   policy: .denied).authorize(.getAppState, arguments: arguments)
        }
        check("Authorize_PolicyDenied_DialogNeverAsked", blocked != nil && blockedDialog.requests.isEmpty)

        // An app approved earlier (by either channel) needs no dialog.
        let approvedStore = AppApprovalStore(storageURL: temporaryStoreURL())
        try await approvedStore.approve(bundle, permanently: false)
        let approvedDialog = DialogRecorder()
        let approved = try await approval(dialog(.denied, approvedDialog), store: approvedStore).authorize(.getAppState, arguments: arguments)
        check("Authorize_AlreadyApproved_DialogNeverAsked",
              approved == .init(bundleIdentifier: bundle, requestedApproval: false) && approvedDialog.requests.isEmpty)

        // Elicitation clients still get the elicitation form.
        let elicitations = DialogRecorder()
        let elicitationStore = AppApprovalStore(storageURL: temporaryStoreURL())
        let elicited = try await approval(.elicitation { parameters in
            elicitations.requests.append(parameters.message)
            return .init(action: .accept)
        }, store: elicitationStore).authorize(.getAppState, arguments: arguments)
        check("Authorize_ElicitationChannel_AsksTheClientForm",
              elicited?.requestedApproval == true && elicitations.requests == ["Allow the agent to use TextEdit?"],
              "\(elicitations.requests)")

        print("\(passed) MCP approval channel tests passed")
    }
}
