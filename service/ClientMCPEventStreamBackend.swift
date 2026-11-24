import Foundation

extension CUAMCPEventStream {
    /// Uses the same genuine service discovery, authorization, connection cache
    /// and typed XPC transport as the existing turn-ended native client.
    static func native(telemetry: @escaping @Sendable (CUAEventStreamTelemetry) -> Void) -> Self {
        .init(status: { try await ComputerUseIPCClient.sendRequest(ComputerUseIPCEventStreamStatusRequest()) },
              start: { try await ComputerUseIPCClient.sendRequest(ComputerUseIPCEventStreamStartRequest()) },
              stop: { try await ComputerUseIPCClient.sendRequest(ComputerUseIPCEventStreamStopRequest(reason: $0)) },
              telemetry: telemetry, serviceDialog: AcuaMCPElicitation.nativeServiceDialog)
    }
}
