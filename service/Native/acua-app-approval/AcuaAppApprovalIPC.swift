import Foundation

/// `ComputerUseIPCAppApprovalRequest`: approval for an MCP client that cannot
/// show an elicitation form. Like the
/// policy request it takes no turn, holds no activity and needs no unlock.
enum AcuaAppApprovalIPC {
    static func perform(_ identifier: String) throws -> JSON {
        let resolved = try Policy.target(for: identifier)
        // Same errors as every other app request: deny list, forbidden apps,
        // computer use turned off, invalid configuration.
        try ComputerUsePolicyIPC.requireApplicationAllowed(identifier)
        let configuration = try ComputerUsePolicyIPC.configuration()

        let highRisk = ApplicationPolicyRisk.isHigh(bundleID: resolved.bundleIdentifier,
            urlTypes: Bundle(path: resolved.appPath)?.object(forInfoDictionaryKey: "CFBundleURLTypes"))
        let target = AcuaAppApprovalTarget(bundleIdentifier: resolved.bundleIdentifier, displayName: resolved.displayName,
                                           warningSubtitle: highRisk ? ApplicationPolicyRisk.warning : nil)
        let decision = AcuaAppApprover(prompt: askOnMainThread).decide(target, apps: configuration.apps)
        return ["decision": decision.rawValue]
    }

    private static func askOnMainThread(_ prompt: AcuaAppApprovalPrompt) -> AcuaAppApprovalAnswer {
        AcuaServiceDialogPresenter.present(dismissed: AcuaAppApprovalAnswer.dismissed) { dismissal in
            AcuaAppApprovalDialog.ask(prompt, dismissal: dismissal)
        }
    }
}

/// `ComputerUseIPCApprovalFormRequest`: the Record & Replay and Messages
/// approvals for an MCP client that cannot show an elicitation form. The
/// helper keeps every approval decision; the service only asks the user.
enum AcuaApprovalFormIPC {
    static func perform(_ body: Any?) throws -> JSON {
        let form = try AcuaApprovalForm(asDict(body) ?? [:])
        let answer = AcuaServiceDialogPresenter.present(dismissed: AcuaApprovalFormDialog.Answer.dismissed) { dismissal in
            AcuaApprovalFormDialog.ask(form, dismissal: dismissal)
        }

        switch answer {
        case .allow(let values): return form.answer(.accept, values: values)
        case .deny: return form.answer(.decline, values: [:])
        case .dismissed: return form.answer(.cancel, values: [:])
        }
    }
}
