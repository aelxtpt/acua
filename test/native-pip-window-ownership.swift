import Foundation

private struct OwnershipCase: Decodable {
    let name: String, windowID: UInt32, role: String, subrole: String?, isModal: Bool
    let parentWindowID: UInt32?, mostRecentWindowID: UInt32?, mainWindowID: UInt32?, existingParentWindowID: UInt32?
    let actual: UInt32?
    var result: UInt32? {
        RemoteHostedPIPWindowOwnership.ownerWindowID(for: windowID, role: role, subrole: subrole, isModal: isModal,
            parentWindowID: parentWindowID, mostRecentWindowID: mostRecentWindowID, mainWindowID: mainWindowID,
            existingParentWindowID: existingParentWindowID)
    }
    var group: String { name.split(separator: "-").dropLast().joined(separator: "-") }
}
private struct Corpus: Decodable { let schema: Int, cases: [OwnershipCase] }

@main enum Tests {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let exporting = args.first == "--ownership-result"
        let path = exporting ? args[1] : (args.first ?? "../test/native-pip-window-ownership-corpus.json")
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        if exporting {
            let result: [[String: Any]] = corpus.cases.map { ["name": $0.name, "actual": $0.result.map { $0 as Any } ?? NSNull()] }
            print("ACUA_OWNERSHIP_RESULT " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: .sortedKeys), as: UTF8.self)); return
        }
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
            checks += 1; print("PASS: \(label)")
        }
        check(corpus.schema == 1 && corpus.cases.count == 331, "ownership corpus keeps 331 typed-argument cases")
        check(Set(corpus.cases.map(\.name)).count == corpus.cases.count, "ownership case names remain unique")
        let groups = Dictionary(grouping: corpus.cases, by: \.group)
        for group in ["sheet-parent", "dialog-order", "explicit-parent", "context", "parent-context", "other-role", "long-role", "long-subrole"] {
            let cases = groups[group] ?? []
            let mismatches = cases.filter { $0.result != $0.actual }.map(\.name)
            check(!cases.isEmpty && mismatches.isEmpty, "\(group) decisions match (\(cases.count) cases); mismatches=\(mismatches)")
        }
        check(corpus.cases.allSatisfy { item in item.result.map { $0 != 0 && $0 != item.windowID } ?? true }, "ownership never returns zero or the window itself")
        check(corpus.cases.allSatisfy { item in item.result.map { [item.parentWindowID, item.mostRecentWindowID, item.mainWindowID, item.existingParentWindowID].contains($0) } ?? true }, "ownership only returns a supplied candidate")
        print("Native PIP ownership checks: \(checks); corpus cases: \(corpus.cases.count)")
    }
}
