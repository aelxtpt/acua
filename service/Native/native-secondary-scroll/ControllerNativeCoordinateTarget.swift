import ApplicationServices
import Darwin
import Foundation

@MainActor struct ControllerNativeCoordinateTarget: ControllerCoordinateTargetBackend {
    typealias Node = ControllerNativeElementContext.Node
    typealias Target = ControllerMouseEventTarget<Node>
    let resources: ControllerNativeResources
    func frame(_ window: Node) -> CGRect? { resources.geometry.frame(window) }
    func element(at point: CGPoint, application: Node) throws -> Node? {
        do {
            if let provider = resources.io.lookup(application.element) {
                guard let provider = provider as? any ControllerNativeMouseHitTestBridge else {
                    throw ControllerNativeMouseHitTestFailure.unsupportedHostedHitTest
                }
                return try provider.element(at: point).map(resources.context.context.node)
            }
            var element: AXUIElement?
            let status = AXUIElementCopyElementAtPosition(application.element.element, Float(point.x), Float(point.y), &element)
            guard status == .success else { throw ControllerNativeElementDecoding.Failure.accessibility(status.rawValue) }
            return element.map { resources.context.context.node(.init(element: $0)) }
        } catch ControllerNativeElementDecoding.Failure.accessibility(let status) where status == AXError.illegalArgument.rawValue {
            return nil
        }
    }
    func target(at point: CGPoint, application: Node, window: Node, element: Node?) throws -> Target {
        try ControllerMouseEventTargeting(backend: ControllerNativeMouseEventTarget(resources: resources))
            .target(at: point, application: application, window: window, element: element)
    }
    private typealias CreateWindowList = @convention(c) (UInt32, UInt32) -> Unmanaged<CFArray>?
    private static let createWindowList: CreateWindowList? = {
        guard let image = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY | RTLD_LOCAL),
              let symbol = dlsym(image, "CGWindowListCreate") else { return nil }
        return unsafeBitCast(symbol, to: CreateWindowList.self)
    }()
    static func orderedWindowIDs() -> [UInt32] {
        // The SDK disables this C API's Swift import. Bind its C ABI directly.
        guard let array = createWindowList?(0x11, 0)?.takeRetainedValue() else { return [] }
        // CGWindowListCreate stores numeric IDs as pointer-sized array values,
        // not retained CFNumbers. Do not bridge this array to [NSNumber].
        return (0..<CFArrayGetCount(array)).map {
            UInt32(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(array, $0)))
        }
    }
}
extension ControllerNativeAppController {
    func orderedWindows() -> [ControllerNativeElementContext.Node] {
        let registered = owner.windows().mapValues(\.node)
        return ControllerOrderedWindows.select(registered: registered, orderedIDs: ControllerNativeCoordinateTarget.orderedWindowIDs())
    }
}
