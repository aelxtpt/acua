import AppKit
import Foundation

@MainActor private final class OwnedView {
    let name: String
    var bounds = CGRect(x: 0.25, y: 1.5, width: 90.5, height: 30.25)
    var offset = CGPoint(x: 10.25, y: 20.5)
    var dark = false
    weak var window: OwnedWindow?
    init(_ name: String) { self.name = name }
}
@MainActor private final class OwnedWindow {
    var content: OwnedView?
    var offset = CGPoint(x: 100.25, y: 200.5)
    var number = 7
    var scale: CGFloat = 2
    init(_ content: OwnedView?) { self.content = content }
}
@MainActor private final class Scene {
    typealias Registry = PermissionRowRegistry<String, OwnedView, String>
    var log = [String]()
    var layoutHook: ((OwnedView) -> Void)?
    lazy var registry = Registry(environment: .init(window: { [unowned self] view in
        log.append("window:" + view.name)
        guard let window = view.window else { return nil }
        return .init(contentView: { [unowned self] in log.append("content");return window.content },
            convertToScreen: { [unowned self] frame in log.append("screen");return frame.offsetBy(dx: window.offset.x, dy: window.offset.y) },
            number: { [unowned self] in log.append("number");return window.number },
            backingScale: { [unowned self] in log.append("scale");return window.scale })
    }, layout: { [unowned self] view in log.append("layout:" + view.name);layoutHook?(view) },
    bounds: { [unowned self] view in log.append("bounds:" + view.name);return view.bounds },
    convertToWindow: { [unowned self] view, rect in log.append("convert:" + view.name);return rect.offsetBy(dx: view.offset.x, dy: view.offset.y) },
    isDark: { [unowned self] view in log.append("dark:" + view.name);return view.dark },
    toQuartz: { [unowned self] point in log.append("quartz");return .init(x: point.x, y: 1000 - point.y) }))
}
@MainActor private final class RetainedValue {}
private final class OwnedPermissionProvider: PermissionRequirementProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var value = "same"
    var identifier: String { lock.withLock { value } }
    func changeIdentifier() { lock.withLock { value = "changed" } }
}

@main enum CatalogueRegistryChecks {
    @MainActor static func main() throws {
        var results = [[String: Any]]()
        func check(_ name: String, _ passed: Bool) { results.append(["name": name, "passed": passed]) }
        if CommandLine.arguments.contains("--invalid-window") {
            let scene = Scene(), view = OwnedView("action"), window = OwnedWindow(nil)
            view.window = window;window.number = CommandLine.arguments.contains("--negative") ? -1 : Int(UInt32.max) + 1
            scene.registry.registerAction(view, for: "x")
            _ = scene.registry.actionLocation(for: "x")
            exit(88)
        }
        func icon(_ value: PermissionCatalog.Row.Icon) -> [String: Any] {
            switch value {
            case let .application(id, fallback): ["kind": "application", "value": id, "fallback": fallback]
            case let .bundle(path, fallback): ["kind": "bundle", "value": path, "fallback": fallback]
            case let .contentType(id, fallback): ["kind": "contentType", "value": id, "fallback": fallback]
            case let .symbol(name): ["kind": "symbol", "value": name]
            }
        }
        func catalogue(_ value: PermissionCatalog) -> [String: Any] {
            let header: [String: Any]
            switch value.headerIcon {
            case let .application(id): header = ["kind": "application", "value": id]
            case let .symbol(name): header = ["kind": "symbol", "value": name]
            case .currentApplication: header = ["kind": "currentApplication"]
            }
            return ["title": value.title, "description": value.description, "headerIcon": header,
                "requestSource": Int(value.requestSource.rawValue), "rows": value.rows.map { row in
                    ["identifier": row.permission.identifier, "title": row.title, "subtitle": row.subtitle,
                     "icon": icon(row.icon), "iconFrameSize": Double(row.iconFrameSize), "isSupplemental": row.isSupplemental] as [String: Any]
                }]
        }
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let expectedCatalogues = fixture["cases"] as! [[String: Any]]
        for pair in expectedCatalogues {
            let name = pair["name"] as! String
            let value: PermissionCatalog
            if let source = pair["source"] as? Int {
                value = .service(source: .init(rawValue: UInt8(source))!)
            } else { value = name == "calendar" ? .calendar : .messages }
            check("complete catalogue " + name, NSDictionary(dictionary: catalogue(value)).isEqual(to: pair["catalogue"] as! [AnyHashable: Any]))
        }
        check("requirement equality/hash use exact identifier", Set([PermissionRequirement(identifier: "x"), .init(identifier: "x"), .init(identifier: "X")]).count == 2)
        check("empty requirement ID remains representable", PermissionRequirement(identifier: "").identifier.isEmpty)
        check("development source exists independently of known presets", PermissionCatalog.Source.development.rawValue == 3)
        check("symbol icon is separate from bundle icon", icon(.symbol("x"))["kind"] as? String == "symbol" && icon(.bundle(path: "x", fallbackSymbol: "y"))["kind"] as? String == "bundle")
        do {
            var first: PermissionRequirement?, second: PermissionRequirement?
            weak var retained: OwnedPermissionProvider?
            do {
                let provider = OwnedPermissionProvider();retained = provider
                first = PermissionRequirement(provider);second = PermissionRequirement(OwnedPermissionProvider())
                provider.changeIdentifier()
                check("requirement snapshots provider identifier once", first?.identifier == "same" && first?.provider.identifier == "changed")
                check("different retained providers with same snapshotted ID compare equal", first == second && (first?.provider as AnyObject?) !== (second?.provider as AnyObject?))
            }
            check("requirement retains concrete provider state", retained != nil && first?.provider is OwnedPermissionProvider)
            first = nil;second = nil
            check("dropping requirements releases provider state", retained == nil)
        }

        do {
            let s = Scene()
            check("missing entry has no capture or action", s.registry.capture(for: "x") == nil && s.registry.actionLocation(for: "x") == nil && s.log.isEmpty)
            let content = OwnedView("content"), source = OwnedView("source"), action = OwnedView("action"), window = OwnedWindow(content)
            source.window = window;action.window = window;source.dark = true
            s.registry.registerSource(source, snapshotProvider: { size, scale, dark in
                s.log.append("render");return "\(size.width):\(size.height):\(scale):\(dark)"
            }, for: "x")
            s.registry.registerAction(action, for: "x")
            let capture = s.registry.capture(for: "x")!
            check("capture geometry is integral with radius24", capture.frameOnScreen == CGRect(x: 110, y: 222, width: 92, height: 31) && capture.cornerRadius == 24)
            check("capture provider gets source bounds, window scale and source theme", capture.artwork == "90.5:30.25:2.0:true")
            check("capture effect order", s.log == ["window:source", "content", "layout:content", "layout:source", "bounds:source", "convert:source", "screen", "bounds:source", "scale", "dark:source", "render"])
            s.log.removeAll()
            let location = s.registry.actionLocation(for: "x")!
            check("action keeps fractional center and converts to Quartz", location == .init(point: .init(x: 156, y: 762.375), windowID: 7))
            check("action does not render and gets ID after coordinate conversion", s.log == ["window:action", "content", "layout:content", "layout:action", "bounds:action", "convert:action", "screen", "quartz", "number"])
            check("source/action updates share one entry", s.registry.entryCount == 1)
            window.content = nil;s.log.removeAll()
            check("capture needs window content", s.registry.capture(for: "x") == nil && s.log == ["window:source", "content"])
            s.log.removeAll()
            check("action permits absent content", s.registry.actionLocation(for: "x") != nil && !s.log.contains("layout:content"))
            window.content = content
            s.registry.registerSource(source, snapshotProvider: nil, for: "x");s.log.removeAll()
            let noProvider = s.registry.capture(for: "x")!
            check("absent renderer preserves capture geometry and nil artwork", noProvider.artwork == nil && noProvider.frameOnScreen == capture.frameOnScreen && noProvider.cornerRadius == 24)
            check("absent renderer skips scale/theme/second bounds", !s.log.contains("scale") && !s.log.contains("dark:source") && s.log.filter { $0 == "bounds:source" }.count == 1)
            s.registry.registerSource(nil, snapshotProvider: nil, for: "x")
            check("clearing source leaves action intact", s.registry.capture(for: "x") == nil && s.registry.actionLocation(for: "x") != nil)
            s.registry.registerSource(source, snapshotProvider: { _, _, _ in nil }, for: "x")
            s.registry.registerAction(nil, for: "x")
            check("clearing action leaves source intact", s.registry.actionLocation(for: "x") == nil && s.registry.capture(for: "x")?.frameOnScreen == capture.frameOnScreen)
            source.window = nil
            check("detached source has no capture", s.registry.capture(for: "x") == nil)
            source.window = window;s.registry.registerAction(action, for: "x");window.number = 0
            check("zero window ID remains valid", s.registry.actionLocation(for: "x")?.windowID == 0)
            window.number = Int(UInt32.max)
            check("maximum UInt32 window ID remains valid", s.registry.actionLocation(for: "x")?.windowID == UInt32.max)
        }
        do {
            let s = Scene(), content = OwnedView("content"), old = OwnedView("old"), replacement = OwnedView("new"), window = OwnedWindow(content)
            old.window = window;replacement.window = window
            old.dark = true;replacement.dark = false
            s.registry.registerSource(old, snapshotProvider: { _, _, _ in "old" }, for: "x")
            s.layoutHook = { view in
                guard view === old else { return }
                old.bounds.size.width = 123.5
                s.registry.registerSource(replacement, snapshotProvider: { size, scale, dark in "new:\(size.width):\(scale):\(dark)" }, for: "x")
            }
            let capture = s.registry.capture(for: "x")!
            check("layout replacement uses new provider with retained old view context", capture.artwork == "new:123.5:2.0:true")
            check("layout replacement geometry comes from old retained source", capture.frameOnScreen.width == 125)
            s.layoutHook = nil
            check("next capture sees replacement source", s.registry.capture(for: "x")?.artwork == "new:90.5:2.0:false")
            s.layoutHook = { view in if view === replacement { s.registry.registerSource(nil, snapshotProvider: nil, for: "x") } }
            let cleared = s.registry.capture(for: "x")
            check("clearing source during layout retains this capture with nil artwork", cleared != nil && cleared?.artwork == nil)
            check("cleared source affects subsequent capture", s.registry.capture(for: "x") == nil)
        }
        do {
            let s = Scene()
            weak var weakSource: OwnedView?, weakAction: OwnedView?, weakProvider: RetainedValue?
            do {
                let source = OwnedView("weak-source"), action = OwnedView("weak-action"), provider = RetainedValue()
                weakSource = source;weakAction = action;weakProvider = provider
                s.registry.registerAction(action, for: "x")
                s.registry.registerSource(source, snapshotProvider: { [provider] _, _, _ in _ = provider;return "alive" }, for: "x")
            }
            check("registry does not retain views", weakSource == nil && weakAction == nil)
            check("dead views leave entry and provider retained", s.registry.entryCount == 1 && weakProvider != nil)
            check("dead weak views have no capture/location", s.registry.capture(for: "x") == nil && s.registry.actionLocation(for: "x") == nil)
            s.registry.registerSource(nil, snapshotProvider: nil, for: "x")
            check("provider replacement releases old context", weakProvider == nil && s.registry.entryCount == 1)
        }
        typealias Native = PermissionRowRegistryEnvironment<NSView>
        let point = CGPoint(x: 7.5, y: 25.25)
        check("zero-screen selection skips earlier noncontaining screen", Native.quartzPoint(point, screenFrames: [.init(x: -1000, y: 0, width: 1000, height: 1000), .init(x: 0, y: -20, width: 1000, height: 1000)]) == .init(x: 7.5, y: 954.75))
        check("zero-screen selection uses first containing screen", Native.quartzPoint(point, screenFrames: [.init(x: 0, y: 0, width: 1000, height: 600), .init(x: 0, y: 0, width: 1000, height: 800)]).y == 574.75)
        check("no zero screen preserves the zero-height fallback", Native.quartzPoint(point, screenFrames: []) == .init(x: 7.5, y: -25.25))
        let passed = results.allSatisfy { $0["passed"] as? Bool == true }
        let payload: [String: Any] = ["passed": passed, "cases": results.count, "results": results,
            "cataloguePairs": expectedCatalogues.count, "nativeUIInputCaptureOrPermissionExecuted": false]
        try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("catalogue/registry checks: \(results.count), passed: \(passed)")
        exit(passed ? 0 : 1)
    }
}
