import AppKit
import Foundation

private final class PasteReadTrace: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    var snapshot: [String] { lock.withLock { values } }
}
@MainActor enum NativePasteboardChecks {
    static func run(output: URL) async throws -> Int32 {
        var checks: [[String:Any]] = []
        func check(_ name: String, _ value: Bool) { checks.append(["name":name,"passed":value]); if !value { print("FAIL: "+name) } }
        let pb = NSPasteboard.withUniqueName()
        precondition(pb.name != NSPasteboard.general.name)
        defer { pb.releaseGlobally() }
        let trace = PasteReadTrace(); var lost = 0
        let backend = ControllerNativePasteboardBackend(pasteboard:pb,readStarted:{ _ in trace.add("start") },
            readFinished:{ start,end,success in precondition(start <= end); trace.add("finish:\(success)") },logOwnershipLost:{ lost += 1 })
        let transaction = ControllerPasteboardTransaction(backend:backend)
        let old = NSPasteboardItem(), other = NSPasteboardItem(), binaryType = NSPasteboard.PasteboardType("local.cua.C120.binary")
        check("owned native item accepts old text and binary representations", old.setString("original",forType:.string) && old.setData(Data([0,255,1]),forType:binaryType) && other.setString("second",forType:.string))
        pb.clearContents()
        check("owned named pasteboard accepts original multi-item contents", pb.writeObjects([old,other]))
        let before = transaction.snapshot()
        check("native snapshot captures all items and representation bytes", before?.count == 2 && before?[0][NSPasteboard.PasteboardType.string.rawValue] == Data("original".utf8) && before?[0][binaryType.rawValue] == Data([0,255,1]) && before?[1][NSPasteboard.PasteboardType.string.rawValue] == Data("second".utf8))
        let session = try transaction.prepare([.init(type:NSPasteboard.PasteboardType.string.rawValue,data:Data("agent text".utf8))])
        check("native transaction binds its original snapshot and current generation", session.snapshot == before && session.generation == pb.changeCount)
        check("native promised provider owns armed item before read", session.provider.rearming.state?.generation == session.generation && session.provider.rearming.state?.count == 0)
        check("native promised read supplies exact UTF8 bytes", pb.pasteboardItems?.first?.data(forType:.string) == Data("agent text".utf8))
        check("native promised read invokes start then successful finish", trace.snapshot.contains("start") && trace.snapshot.contains("finish:true") && !session.provider.failedToProvideData)
        var iterator = session.provider.reads.makeAsyncIterator()
        let read: Void? = await iterator.next()
        check("native successful read wakes its bufferingNewest stream", read != nil)
        let deadline = ContinuousClock.now.advanced(by:.milliseconds(150))
        while session.provider.rearming.state?.count == 0 && ContinuousClock.now < deadline { try await Task.sleep(for:.milliseconds(2)) }
        check("native main-queue rearming executes while generation is owned", (session.provider.rearming.state?.count ?? 0) >= 1 && pb.changeCount == session.generation)
        check("native restore returns original ownership", transaction.restore(session))
        check("native restore reproduces all original item data", transaction.snapshot() == before && session.provider.rearming.state == nil)
        let late = NSPasteboardItem()
        session.provider.pasteboard(nil,item:late,provideDataForType:.string)
        check("retained provider still supplies late read after restore", late.data(forType:.string) == Data("agent text".utf8))
        try await Task.sleep(for:.milliseconds(5))
        check("queued late rearm does not revive a cleared tuple", session.provider.rearming.state == nil && transaction.snapshot() == before)
        session.provider.pasteboard(pb,item:NSPasteboardItem(),provideDataForType:.init("local.cua.C120.unknown"))
        check("unknown native representation marks sticky failure and failed finish", session.provider.failedToProvideData && trace.snapshot.last == "finish:false")
        let later = NSPasteboardItem(); session.provider.pasteboard(pb,item:later,provideDataForType:.string)
        check("later success does not reset provider failure", later.data(forType:.string) == Data("agent text".utf8) && session.provider.failedToProvideData && trace.snapshot.last == "finish:true")
        let changed = try transaction.prepare([.init(type:NSPasteboard.PasteboardType.string.rawValue,data:Data("temporary".utf8))])
        pb.clearContents(); _ = pb.setString("new owner",forType:.string)
        check("native ownership loss returns false without restoring previous clipboard", !transaction.restore(changed) && pb.string(forType:.string) == "new owner" && lost == 1 && changed.provider.rearming.state == nil)
        try await Task.sleep(for:.milliseconds(5))
        check("native queued provider callbacks preserve new owner contents", pb.string(forType:.string) == "new owner")
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject:["passed":passed,"cases":checks,
            "actual_owned_named_NSPasteboard_snapshot_promises_rearming_restoration_executed":true,
            "general_pasteboard_transaction_executed":false,"actual_input_focus_or_screen_capture_executed":false,
            "whole_paste_engine_implemented":false,"native_global_paste_queue_or_ordinary_handlers_integrated":false],options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native pasteboard: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
