import Foundation

@main struct Tests {
    @MainActor static func main() {
        var checks = 0
        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            precondition(condition(), "FAIL: \(name)"); checks += 1; print("PASS: \(name)")
        }
        var trace: [String] = []
        var name: String? = "Live", bundle: String? = "com.example.app", securePID: Int? = 7
        let resolver = EventStreamApplicationResolver(runningApplication: {
            trace.append("lookup:\($0)")
            return .init(name: name, bundleIdentifier: bundle)
        }, applicationURL: { _ in nil }, bundleDetails: { _ in nil }, executablePath: { _ in nil })
        func snapshot(_ fallback: String? = "Fallback", pid: Int32 = 7) -> EventStreamApp? {
            resolver.snapshot(processIdentifier: pid, fallbackName: fallback, secureInputPID: {
                trace.append("secure"); return securePID
            })
        }
        let first = snapshot()
        check("live application name takes priority", first?.name == "Live")
        check("PID secure input and bundle are sampled", first?.processIdentifier == 7 && first?.secureInput == true && first?.bundleIdentifier == "com.example.app")
        check("metadata reads follow name secure input then independent bundle lookup", trace == ["lookup:7", "secure", "lookup:7"])
        name = nil; check("nil live name uses fallback", snapshot()?.name == "Fallback")
        name = ""; check("empty live name also uses fallback", snapshot()?.name == "Fallback")
        name = " \n "; check("whitespace live name is retained", snapshot()?.name == " \n ")
        name = nil; trace = []
        check("nameless application yields nil", snapshot(nil) == nil)
        check("nameless path skips secure input and bundle lookup", trace == ["lookup:7"])
        trace = []; check("empty fallback also yields nil", snapshot("") == nil && trace == ["lookup:7"])
        check("whitespace fallback is retained", snapshot(" ")?.name == " ")
        name = "Live"; securePID = nil
        check("missing secure input state is false", snapshot()?.secureInput == false)
        securePID = 8; check("another process holding secure input is false", snapshot()?.secureInput == false)
        securePID = 0; check("zero PID is compared without invented validation", snapshot(pid: 0)?.secureInput == true)
        securePID = -1; check("negative PID is preserved and compared", snapshot(pid: -1)?.processIdentifier == -1 && snapshot(pid: -1)?.secureInput == true)
        bundle = nil; check("missing bundle does not discard named application", snapshot()?.name == "Live" && snapshot()?.bundleIdentifier == nil)
        bundle = ""; check("empty bundle becomes nil", snapshot()?.bundleIdentifier == nil)
        bundle = " \t "; check("whitespace bundle is retained", snapshot()?.bundleIdentifier == " \t ")
        name = ""; trace = []; check("empty live and absent fallback short circuit", snapshot(nil) == nil && trace == ["lookup:7"])
        print("\(checks) checks")
    }
}
