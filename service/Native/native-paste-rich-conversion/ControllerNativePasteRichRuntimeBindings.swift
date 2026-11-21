import Foundation

extension ControllerNativePasteRuntime {
    static func native(resources: ControllerNativeResources) -> Self { .native(resources:resources,rendering:.native) }
}

extension ControllerNativeAppController {
    func performPaste(_ parameters: ControllerPasteParameters) async throws -> AppSnapshot? {
        try await performPaste(parameters,runtime:.native(resources:resources))
    }
}
