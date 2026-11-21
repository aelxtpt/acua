import ApplicationServices
import Foundation

/// Typed write on the captured/refetchable element. Field focus,
/// autosubmit and post-action appSnapshot belong to the surrounding action.
@MainActor enum ControllerNativeStringValueWriter {
    static func set(_ text: String, on element: ControllerNativeResolvedElement,
                    resources: ControllerNativeResources) throws {
        func contextual() -> ControllerNativeElementContext.Node {
            ControllerNativeAppSnapshotContext.contextual(element.node.element)
        }
        // Read only the captured encoded AXValue, with no live fallback.
        func encodedValue() -> AnyObject? { element.node.element.cachedAttribute("AXValue") }
        let geometry = resources.geometry
        let kind = ControllerStringValueConversion.kind(encodedValue: encodedValue,
            role: { resources.context.context.role(contextual()) },
            subrole: { geometry.value("AXSubrole", on: contextual(), as: String.self) })
        let converted = try ControllerStringValueConversion.convert(text, kind: kind,
            encodedValue: encodedValue, dateTimeComponents: {
                let mask: Int = geometry.value("AXDateTimeComponents", on: contextual()) ?? 238
                // Keep the checked signed-to-unsigned conversion.
                return UInt(mask)
            })
        let value = ControllerNativeAXValue(raw: converted.foundationValue)
        try element.afterWriting { node in
            // The existing writer implements hosted-provider priority,
            // all-error propagation and self-process/main-thread dispatch.
            try ControllerNativeClickablePoint(geometry: geometry).write(value,
                attribute: "AXValue", node: ControllerNativeAppSnapshotContext.contextual(node.element), refreshLeaf: false)
        }
    }
}
