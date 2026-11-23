import Foundation
import MCP

/// ACUA only: asks the service to show an approval form for an MCP client
/// without elicitation. The service answers in the elicitation result shape.
struct ComputerUseIPCApprovalFormRequest: ComputerUseIPCRequest, Sendable {
    typealias Response = CreateElicitation.Result
    let message: String
    let detail: String?
    let requestedSchema: Elicitation.RequestSchema
}

extension AcuaMCPElicitation {
    /// The service's dialog. A cancelled tool call stops waiting for it, but
    /// the dialog stays until it is answered, times out or the helper exits.
    static let nativeServiceDialog: Ask = { form in
        try await ComputerUseIPCClient.sendRequest(ComputerUseIPCApprovalFormRequest(
            message: form.message, detail: form.detail, requestedSchema: form.schema))
    }
}
