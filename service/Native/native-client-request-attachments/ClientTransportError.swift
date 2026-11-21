import Foundation

extension ComputerUseIPCXPCTransport {
    enum Error: Swift.Error, LocalizedError, CaseIterable {
        case couldNotAllocateBootstrapPort
        case couldNotEncodeBootstrapPort
        case bootstrapTimedOut
        case couldNotReceiveEndpoint
        case invalidFileDescriptor
        case missingRemoteProxy
        case missingResponseData
        case remoteConnection

        var errorDescription: String? {
            self == .bootstrapTimedOut ? "Timed out establishing the Computer Use connection." : nil
        }
    }
}

typealias ClientTurnEndedTransport = ComputerUseIPCXPCTransport
typealias ClientTransportFailure = ComputerUseIPCXPCTransport.Error
