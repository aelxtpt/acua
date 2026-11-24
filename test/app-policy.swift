import Foundation

@main enum AppPolicyTests {
    static func main() throws {
        var passed = 0
        func check(_ name: String, _ value: Bool) {
            precondition(value, name); passed += 1; print("PASS \(name)")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("cua-policy-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        func fixture(_ name: String, displayName: String?, bundleName: String?) throws -> URL {
            let bundle = temporary.appendingPathComponent(name + ".app")
            let contents = bundle.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: JSON = ["CFBundleIdentifier": "test.acua.policy.\(name)", "CFBundlePackageType": "APPL"]
            if let displayName { info["CFBundleDisplayName"] = displayName }
            if let bundleName { info["CFBundleName"] = bundleName }
            try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return bundle
        }
        let named = try fixture("Named", displayName: "Owned Display", bundleName: "Owned Bundle")
        let target = try Policy.target(for: named.path)
        check("policy resolves an app bundle without requiring a running process", target.bundleIdentifier == "test.acua.policy.Named")
        check("display name precedes bundle name", target.displayName == "Owned Display")
        check("policy carries the installed bundle path", target.appPath == named.standardizedFileURL.path)
        let bundleNamed = try fixture("BundleNamed", displayName: nil, bundleName: "Owned Bundle")
        check("bundle name supplies missing display name", try Policy.target(for: bundleNamed.path).displayName == "Owned Bundle")
        let unnamed = try fixture("Filename", displayName: nil, bundleName: nil)
        check("filename supplies missing bundle names", try Policy.target(for: unnamed.path).displayName == "Filename")
        let empty = try fixture("EmptyDisplay", displayName: "", bundleName: "Owned Bundle")
        check("an explicitly empty display name remains an empty string", try Policy.target(for: empty.path).displayName.isEmpty)
        let link = temporary.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: named)
        check("policy resolves symlink targets to the canonical path", try Policy.target(for: link.path).appPath == named.standardizedFileURL.path)
        let missing = "test.acua.missing.\(UUID().uuidString)"
        do {
            _ = try Policy.decision(for: missing)
            preconditionFailure("Nonexistent app became a policy target")
        } catch let error as ServiceError {
            check("missing app reports the invalid-app error code", error.code == .invalidApp)
            check("missing app reports the client-visible error text", error.message == "Invalid app: \(missing)")
        }
        check("metadata-only fixtures never require a launched app", AppResolver.resolve(target.bundleIdentifier) == nil)
        let defaults = Policy.render(target: target, policy: .defaults)
        check("persistent approval is encoded at the result root", defaults["allowPersistentApproval"] as? Bool == true)
        check("persistent approval is absent from the target descriptor", (defaults["target"] as? JSON)?["allowPersistentApproval"] == nil)
        let restricted = ComputerUsePolicy(configuration: AcuaConfiguration(apps: AcuaAppAccessConfiguration(
            defaultAccess: .deny, allowPersistentApproval: false)))
        let denied = Policy.render(target: target, policy: restricted)
        check("configuration can deny an otherwise allowed application", denied["decision"] as? String == "denied")
        check("persistent approval follows configuration", denied["allowPersistentApproval"] as? Bool == false)
        let terminal = Policy.Target(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal", appPath: named.path)
        let high = Policy.render(target: terminal, policy: .defaults)
        check("forbidden terminal retains its high risk descriptor", high["decision"] as? String == "forbidden" && (high["target"] as? JSON)?["risk"] as? String == "high")
        check("high-risk targets include the risk warning", (high["target"] as? JSON)?["warningSubtitle"] as? String == ApplicationPolicyRisk.warning)
        check("configuration denial precedes the forbidden-target classification", Policy.render(target: terminal, policy: restricted)["decision"] as? String == "denied")
        // ACUA only: the result says whether [apps].allow lists the app, so
        // the client skips approval on every channel.
        check("Render_DefaultPolicy_NotPreApproved", defaults["preApproved"] as? Bool == false)
        let listing = ComputerUsePolicy(configuration: AcuaConfiguration(apps: AcuaAppAccessConfiguration(
            allowedBundleIdentifiers: [target.bundleIdentifier.uppercased(), "com.apple.Terminal"])))
        check("Render_AppInAppsAllow_PreApproved", Policy.render(target: target, policy: listing)["preApproved"] as? Bool == true)
        let listedAndDenied = ComputerUsePolicy(configuration: AcuaConfiguration(apps: AcuaAppAccessConfiguration(
            allowedBundleIdentifiers: [target.bundleIdentifier], deniedBundleIdentifiers: [target.bundleIdentifier])))
        let deniedRender = Policy.render(target: target, policy: listedAndDenied)
        check("Render_AppInAllowAndDeny_DeniedAndNotPreApproved",
              deniedRender["decision"] as? String == "denied" && deniedRender["preApproved"] as? Bool == false)
        let listedForbidden = Policy.render(target: terminal, policy: listing)
        check("Render_ForbiddenAppInAppsAllow_NotPreApproved",
              listedForbidden["decision"] as? String == "forbidden" && listedForbidden["preApproved"] as? Bool == false)
        print("ALL \(passed) APP POLICY TARGET CHECKS PASSED")
    }
}
