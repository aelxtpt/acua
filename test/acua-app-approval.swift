import Foundation

// Unit tests for the service-side app approval used by MCP clients that do not
// support elicitation: `[apps].allow` pre-approves, anything else asks the user
// through the native dialog. The dialog is a fake; nothing is shown.

private final class PromptRecorder: @unchecked Sendable {
    var prompts: [AcuaAppApprovalPrompt] = []
}

@main
enum AcuaAppApprovalTests {
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

    private static let textEdit = AcuaAppApprovalTarget(bundleIdentifier: "com.apple.TextEdit", displayName: "TextEdit",
                                                        warningSubtitle: nil)
    private static let terminal = AcuaAppApprovalTarget(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal",
                                                        warningSubtitle: "High risk")

    private static func apps(allow: Set<String> = [], deny: Set<String> = [], defaultAccess: AcuaAppAccess = .allow,
                             enabled: Bool = true, persistent: Bool = true) -> AcuaAppAccessConfiguration {
        var apps = AcuaAppAccessConfiguration()
        apps.enabled = enabled
        apps.defaultAccess = defaultAccess
        apps.allowedBundleIdentifiers = allow
        apps.deniedBundleIdentifiers = deny
        apps.allowPersistentApproval = persistent
        return apps
    }

    private static func decide(_ target: AcuaAppApprovalTarget, _ apps: AcuaAppAccessConfiguration,
                               answer: AcuaAppApprovalAnswer) -> (AcuaAppApprovalDecision, [AcuaAppApprovalPrompt]) {
        let recorder = PromptRecorder()
        let approver = AcuaAppApprover(prompt: { prompt in
            recorder.prompts.append(prompt)
            return answer
        })
        return (approver.decide(target, apps: apps), recorder.prompts)
    }

    static func main() {
        let (listed, listedPrompts) = decide(textEdit, apps(allow: ["com.apple.TextEdit"]), answer: .deny)
        check("Decide_AppInAllowList_PreApprovedWithoutDialog", listed == .preApproved && listedPrompts.isEmpty,
              "\(listed) prompts=\(listedPrompts.count)")

        // default_access = deny still lets an allow-listed app through.
        let (listedDenyByDefault, _) = decide(textEdit, apps(allow: ["com.apple.TextEdit"], defaultAccess: .deny), answer: .deny)
        check("Decide_AllowListedWithDefaultDeny_PreApproved", listedDenyByDefault == .preApproved)

        let (caseListed, caseListedPrompts) = decide(textEdit, apps(allow: ["COM.APPLE.TEXTEDIT"]), answer: .deny)
        check("Decide_AllowListDifferentCase_PreApprovedWithoutDialog", caseListed == .preApproved && caseListedPrompts.isEmpty)

        let (session, sessionPrompts) = decide(textEdit, apps(), answer: .allowForSession)
        check("Decide_UnlistedAppAllowedForSession_AllowedForSession", session == .allowedForSession && sessionPrompts.count == 1)
        check("Decide_UnlistedApp_DialogNamesTheApp",
              sessionPrompts.first == AcuaAppApprovalPrompt(displayName: "TextEdit", bundleIdentifier: "com.apple.TextEdit",
                                                         warning: nil, offersAlwaysAllow: true), "\(sessionPrompts)")

        let (always, _) = decide(textEdit, apps(), answer: .alwaysAllow)
        check("Decide_UnlistedAppAlwaysAllowed_AllowedAlways", always == .allowedAlways)

        let (denied, _) = decide(textEdit, apps(), answer: .deny)
        check("Decide_UserDenies_Denied", denied == .denied)

        let (dismissed, _) = decide(textEdit, apps(), answer: .dismissed)
        check("Decide_DialogDismissedOrTimedOut_Canceled", dismissed == .canceled)

        let (_, noPersistencePrompts) = decide(textEdit, apps(persistent: false), answer: .allowForSession)
        check("Decide_PersistentApprovalDisabled_DialogHidesAlwaysAllow",
              noPersistencePrompts.first?.offersAlwaysAllow == false)

        // A peer answer the dialog never offered is not honored as permanent.
        let (forcedAlways, _) = decide(textEdit, apps(persistent: false), answer: .alwaysAllow)
        check("Decide_AlwaysAllowNotOffered_AllowedOnlyForSession", forcedAlways == .allowedForSession, "\(forcedAlways)")

        let (_, riskyPrompts) = decide(terminal, apps(), answer: .allowForSession)
        check("Decide_HighRiskApp_DialogShowsTheWarning", riskyPrompts.first?.warning == "High risk")

        // The deny list wins over the allow list and never shows a dialog.
        let (blocked, blockedPrompts) = decide(textEdit, apps(deny: ["com.apple.TextEdit"]), answer: .allowForSession)
        check("Decide_AppInDenyList_DeniedWithoutDialog", blocked == .denied && blockedPrompts.isEmpty)

        let (defaultDenied, defaultDeniedPrompts) = decide(textEdit, apps(defaultAccess: .deny), answer: .allowForSession)
        check("Decide_UnlistedAppWithDefaultDeny_DeniedWithoutDialog", defaultDenied == .denied && defaultDeniedPrompts.isEmpty)

        let (disabled, disabledPrompts) = decide(textEdit, apps(allow: ["com.apple.TextEdit"], enabled: false), answer: .allowForSession)
        check("Decide_ComputerUseDisabled_DeniedWithoutDialog", disabled == .denied && disabledPrompts.isEmpty)

        print("\(passed) app approval tests passed")
    }
}
