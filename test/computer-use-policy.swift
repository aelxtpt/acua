import Foundation

@main enum ComputerUsePolicyTests {
    static func main() {
        func check(_ name: String, _ value: Bool) { precondition(value, name); print("PASS \(name)") }
        check("both risk lists contain eleven identifiers", ApplicationPolicyRisk.terminalIDs.count == 11 && ApplicationPolicyRisk.elevatedIDs.count == 11)
        for id in ApplicationPolicyRisk.terminalIDs.union(ApplicationPolicyRisk.elevatedIDs).sorted() {
            check("high-risk target \(id)", ApplicationPolicyRisk.isHigh(bundleID: id, urlTypes: nil))
        }
        check("unlisted apps without HTTP handlers remain low-risk", !ApplicationPolicyRisk.isHigh(bundleID: "owned", urlTypes: nil))
        check("HTTP handlers are high-risk", ApplicationPolicyRisk.isHigh(bundleID: "owned", urlTypes: [["CFBundleURLSchemes": ["http"]]]))
        check("HTTP matching is exact rather than case-folded", !ApplicationPolicyRisk.isHigh(bundleID: "owned", urlTypes: [["CFBundleURLSchemes": ["HTTP", "https"]]]))
        check("malformed URL scheme arrays are ignored", !ApplicationPolicyRisk.isHigh(bundleID: "owned", urlTypes: [["CFBundleURLSchemes": ["http", 1]]]))
    }
}
