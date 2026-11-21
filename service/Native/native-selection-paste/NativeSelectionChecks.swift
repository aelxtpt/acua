import AppKit
import ApplicationServices
import Foundation

private final class SelectionPlainBridge: ControllerNativeElementBridge, Sendable {
    var ordinaryPID: Int32 { 0 }; var actualPID: Int32 { 0 }; var windowID: UInt32 { 51 }; var bundleIdentifier: String? { nil }
    func supported() -> Set<String> { [] }
    func batch(_ attributes: Set<String>) throws -> [String: ControllerNativeAXValue] { [:] }
    func read(_ attribute: String) throws -> ControllerNativeAXValue? { throw SelectionDataFailure.unexpected }
    func perform(_ action: String) throws { throw SelectionDataFailure.unexpected }
    func actions() -> [String] { [] }
    func count(_ attribute: String) -> Int? { nil }
    func isSettable(_ attribute: String) -> Bool { false }
    func setBoolean(_ attribute: String, _ value: Bool) throws { throw SelectionDataFailure.unexpected }
}
@MainActor enum NativeSelectionChecks {
    static func decodeRange(_ value: ControllerNativeAXValue) -> CFRange? {
        guard CFGetTypeID(value.raw) == AXValueGetTypeID() else { return nil }
        let native = unsafeDowncast(value.raw,to:AXValue.self)
        guard AXValueGetType(native) == .cfRange else { return nil }
        var range = CFRange(); return AXValueGetValue(native,.cfRange,&range) ? range : nil
    }
    static func run(output: URL) async throws -> Int32 {
        var checks: [[String:Any]] = []
        func check(_ name: String, _ passed: Bool) { checks.append(["name":name,"passed":passed]); if !passed { print("FAIL: "+name) } }
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let f = SelectionDataFixture(), io = ControllerNativeSelectionIO(resources: f.resources)
        let h = try f.handle("old" as NSString,extra:["AXSelectedTextRange":"declared" as NSString])
        let range = NSRange(location:2,length:4)
        let frame = try io.bounds(range,element:h)
        let observed = f.bridge.parameters.first.flatMap { decodeRange($0.1) }
        check("native range bounds uses hosted parameterized capability with actual CFRange value", frame == .init(x:10,y:20,width:30,height:40) && f.bridge.parameters.first?.0 == "AXBoundsForRange" && observed?.location == 2 && observed?.length == 4)
        check("bounds lookup performs no write or refetch", f.bridge.writes.isEmpty && f.refreshes == 0)
        f.bridge.returnedFrame = nil
        check("present hosted nil bounds remains nil", try io.bounds(range,element:h) == nil)
        f.bridge.failParameter = true; var failed = false
        do { _ = try io.bounds(range,element:h) } catch SelectionDataFailure.unexpected { failed = true }
        check("hosted parameterized error propagates without raw AX fallback", failed && f.refreshes == 0)
        f.bridge.failParameter = false
        try io.write(range,element:h)
        let written = f.bridge.writes.first.flatMap { decodeRange($0.1) }
        check("native selectedTextRange write sends a typed range rather than selected text", f.bridge.writes.first?.0 == "AXSelectedTextRange" && written?.location == 2 && written?.length == 4)
        check("successful selected range write runs refetch after provider write", f.refreshes == 1 && f.writesBeforeRefresh && h.node.value == "after")
        f.bridge.failWrite = true; failed = false
        do { try io.write(.init(location:1,length:0),element:h) } catch SelectionDataFailure.write { failed = true }
        check("failed selected range write skips refetch and preserves node", failed && f.refreshes == 1 && h.node.value == "after")
        let sentinel = try io.parameter(.init(location:NSNotFound,length:0))
        check("NSNotFound range location maps to CFNotFound", decodeRange(sentinel)?.location == kCFNotFound)
        let plain = SelectionPlainBridge()
        let resources = ControllerNativeResources(context:f.resources.context,lookup:{ _ in plain },windowServer:f.resources.windowServer)
        let noCapabilities = ControllerNativeSelectionIO(resources:resources)
        failed = false
        do { _ = try noCapabilities.bounds(range,element:h) } catch ControllerNativeSelectionIOFailure.unsupportedHostedParameterizedValue { failed = true }
        check("hosted provider without parameterized capability never falls through to raw AX", failed)
        failed = false
        do { try noCapabilities.write(range,element:h) } catch ControllerNativePointWriteFailure.unsupportedHostedValueWrite { failed = true }
        check("hosted provider without typed writer never falls through to raw AX", failed && f.refreshes == 1)
        var node = h.node; node.value = "A😀B"; node.capturedValueIsBooleanConvertible = false
        let parameters = ControllerTextSelectionParameters(elementID:1,text:"😀",returnAppSnapshot:false)
        check("native node source range uses UTF16 offsets", ControllerNativeTextSelectionBackend.sourceRange(node,parameters:parameters) == .init(location:1,length:2))
        var rich = EventStreamTransformedString()
        rich.appendMappedString("😀",sourceOffsets:[9,10]);node.transformedString = rich;node.truncationRange = .init(location:100,length:12)
        check("native source mapping preserves rich offsets and truncation", ControllerNativeTextSelectionBackend.sourceRange(node,parameters:parameters) == .init(location:109,length:2))
        node.transformedString = nil;node.truncationRange = nil;node.capturedValueIsBooleanConvertible = true
        check("captured Boolean-convertible value suppresses string source fallback", ControllerNativeTextSelectionBackend.sourceRange(node,parameters:parameters) == nil)
        node.attributedString = NSAttributedString(string:"A😀B")
        check("attributed source remains usable for Boolean-convertible captured value", ControllerNativeTextSelectionBackend.sourceRange(node,parameters:parameters) == .init(location:1,length:2))
        let g = SelectionDataFixture(), element = try g.handle("text" as NSString)
        let runtime = ControllerNativeTextSelectionRuntime.native(resources:g.resources)
        _ = try runtime.bounds(.init(location:0,length:1),element)
        check("default native bounds runtime calls native provider", g.bridge.parameters.count == 1)
        let revealed = try await runtime.reveal(element,.init(x:0,y:0,width:10,height:10))
        check("default native reveal executes unchanged plan without a write", !revealed && g.bridge.writes.isEmpty && g.refreshes == 0)
        check("native selection checks preserve foreground application", foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier)
        let passed = checks.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject:["passed":passed,"cases":checks,
            "actual_AXValue_CFRange_construction_executed":true,"native_selection_hosted_bounds_write_refetch_source_mapping_executed":true,
            "default_native_bounds_and_reveal_providers_executed":true,"actual_AX_write_focus_cursor_keyboard_clipboard_or_capture":false,
            "whole_native_selectText_controller_executed":false,"ordinary_native_selection_routing_accepted":false,
            "paste_engine_implemented":false,"foreground_unchanged":foreground == NSWorkspace.shared.frontmostApplication?.processIdentifier],
            options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("Native selection: \(checks.filter { $0["passed"] as? Bool == true }.count)/\(checks.count)")
        return passed ? 0 : 3
    }
}
